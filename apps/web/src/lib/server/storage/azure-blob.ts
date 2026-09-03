/**
 * The Azure Blob Storage backend for {@link WorkspaceStorage}'s wire operations.
 *
 * Azure Blob has **no S3-compatible API**. That is the whole reason this file
 * exists: every other non-AWS target this application supports (MinIO, R2,
 * Wasabi) is reached by pointing `S3_ENDPOINT` at it, and there is no endpoint
 * that makes Blob speak S3. The container/blob data model does map cleanly onto
 * bucket/key, so the port is a driver and not a redesign.
 *
 * ## What this file is, and what it deliberately is not
 *
 * It implements exactly the five wire operations and **nothing else**. It does
 * not resolve configuration, does not read the ambient workspace, and does not
 * compose object names. All of that stays in `s3.ts`, which hands this module a
 * connection captured once at construction and object names that are already
 * namespaced and already validated by `composeNamespacedKey`.
 *
 * That split is load-bearing rather than tidy. The namespacing rules in
 * `namespace.ts` are the property that keeps one workspace out of another's
 * objects in a shared bucket, and they are enforced on the *composed name*. A
 * driver that re-derived names would be a second, unreviewed place for that
 * property to be wrong, and it would be wrong only under the backend that gets
 * the least testing. So the driver's contract is: it receives a finished object
 * name and puts it on the wire verbatim.
 *
 * ## Field mapping
 *
 * The connection keeps its S3 field names — see `config.ts`'s `storageDriver`
 * for why the env vars did not get renamed:
 *
 * | connection field    | Azure meaning                                       |
 * | ------------------- | --------------------------------------------------- |
 * | `bucket`            | container name                                       |
 * | `accessKeyId`       | storage account name                                 |
 * | `secretAccessKey`   | storage account key                                  |
 * | `endpoint`          | blob endpoint; defaults to the public-cloud hostname |
 * | `region`            | unused — Azure encodes location in the account       |
 * | `forcePathStyle`    | unused — Blob URLs are always path-style             |
 *
 * `region` and `forcePathStyle` being inert is worth stating rather than
 * leaving to be discovered: they remain in the connection because the type is
 * shared with the S3 driver and because `connectionKey` hashes them into the
 * client cache key, which is harmless. Nothing here reads them.
 */
import { createHash } from 'node:crypto'
import { Readable } from 'node:stream'

/**
 * The connection parameters one blob client is built from.
 *
 * Structurally the same value `s3.ts` builds for the S3 driver, redeclared here
 * so this module imports no runtime value from `s3.ts` — `s3.ts` imports *this*
 * file, and a type-only back-edge is still an edge a future refactor can make
 * real.
 */
export interface AzureBlobConnection {
  endpoint?: string
  bucket: string
  region: string
  accessKeyId: string
  secretAccessKey: string
  forcePathStyle: boolean
}

/** A streamed object read. Matches `S3ObjectResult` structurally. */
export interface AzureBlobObjectResult {
  body: ReadableStream<Uint8Array>
  contentType: string
}

/** The wire half of `WorkspaceStorage`: object names arrive already composed. */
export interface AzureBlobOperations {
  presignPut(objectName: string, contentType: string, expiresIn: number): Promise<string>
  put(objectName: string, body: Buffer | Uint8Array, contentType: string): Promise<void>
  get(objectName: string): Promise<AzureBlobObjectResult>
  presignGet(objectName: string, expiresIn: number, downloadName?: string): Promise<string>
  remove(objectName: string): Promise<void>
}

// ============================================================================
// Structural types for the @azure/storage-blob surface we use
// ============================================================================

/*
 * Declared structurally, matching how `s3.ts` types the AWS SDK. The package is
 * loaded through a dynamic import so an install that never sets
 * STORAGE_DRIVER=azure_blob does not pay for it, and so a build that omits the
 * optional dependency still type-checks.
 */

interface BlockBlobClientInstance {
  readonly url: string
  uploadData(
    data: Buffer | Uint8Array,
    options?: { blobHTTPHeaders?: { blobContentType?: string } }
  ): Promise<unknown>
  download(): Promise<{
    readableStreamBody?: NodeJS.ReadableStream
    contentType?: string
  }>
  deleteIfExists(): Promise<unknown>
}

interface ContainerClientInstance {
  getBlockBlobClient(blobName: string): BlockBlobClientInstance
}

interface BlobServiceClientInstance {
  getContainerClient(containerName: string): ContainerClientInstance
}

interface SharedKeyCredentialInstance {
  readonly accountName: string
}

interface BlobSASPermissionsInstance {
  toString(): string
}

interface SASQueryParametersInstance {
  toString(): string
}

interface AzureBlobModule {
  BlobServiceClient: new (
    url: string,
    credential: SharedKeyCredentialInstance
  ) => BlobServiceClientInstance
  StorageSharedKeyCredential: new (
    accountName: string,
    accountKey: string
  ) => SharedKeyCredentialInstance
  BlobSASPermissions: { parse(permissions: string): BlobSASPermissionsInstance }
  generateBlobSASQueryParameters: (
    options: {
      containerName: string
      blobName: string
      permissions: BlobSASPermissionsInstance
      startsOn?: Date
      expiresOn: Date
      contentDisposition?: string
      contentType?: string
      protocol?: string
    },
    credential: SharedKeyCredentialInstance
  ) => SASQueryParametersInstance
  SASProtocol: { Https: string; HttpsAndHttp: string }
}

let _azureModule: AzureBlobModule | null = null

async function getAzureModule(): Promise<AzureBlobModule> {
  if (_azureModule) return _azureModule
  _azureModule = (await import('@azure/storage-blob')) as unknown as AzureBlobModule
  return _azureModule
}

// ============================================================================
// Client cache
// ============================================================================

/**
 * One service client per set of connection parameters.
 *
 * Keyed by the parameters and not by the asking workspace, for exactly the
 * reason `s3.ts` spells out at its own cache: a client is a signer and a
 * connection pool built from an endpoint and a credential, so keying it by who
 * asked is what lets a client captured under one scope serve another scope's
 * request against the wrong account.
 */
interface CachedClient {
  service: BlobServiceClientInstance
  credential: SharedKeyCredentialInstance
}

const blobClients = new Map<string, CachedClient>()
const MAX_BLOB_CLIENTS = 256

/**
 * A stable, non-secret-bearing name for one set of connection parameters.
 * The account key is hashed rather than embedded because this string is a Map
 * key that a future debug log would happily print.
 */
function connectionKey(connection: AzureBlobConnection): string {
  const credential = createHash('sha256')
    .update(`${connection.accessKeyId}\u0000${connection.secretAccessKey}`)
    .digest('hex')
    .slice(0, 16)
  return `${resolveEndpoint(connection)}|${credential}`
}

/**
 * The blob service endpoint.
 *
 * An explicit `S3_ENDPOINT` wins so that Azurite and private-link/custom-domain
 * accounts work; otherwise the public-cloud hostname is derived from the
 * account name. Sovereign clouds (`.core.chinacloudapi.cn`,
 * `.core.usgovcloudapi.net`) are reached by setting the endpoint explicitly —
 * guessing a sovereign suffix from an account name is not possible.
 */
function resolveEndpoint(connection: AzureBlobConnection): string {
  const explicit = connection.endpoint?.trim()
  if (explicit) return explicit.replace(/\/+$/, '')
  return `https://${connection.accessKeyId}.blob.core.windows.net`
}

async function getClient(connection: AzureBlobConnection): Promise<CachedClient> {
  const key = connectionKey(connection)
  const existing = blobClients.get(key)
  if (existing) return existing

  const { BlobServiceClient, StorageSharedKeyCredential } = await getAzureModule()
  const credential = new StorageSharedKeyCredential(
    connection.accessKeyId,
    connection.secretAccessKey
  )
  const service = new BlobServiceClient(resolveEndpoint(connection), credential)

  const cached: CachedClient = { service, credential }
  blobClients.set(key, cached)
  while (blobClients.size > MAX_BLOB_CLIENTS) {
    const oldest = blobClients.keys().next()
    if (oldest.done) break
    blobClients.delete(oldest.value)
  }
  return cached
}

async function getBlob(
  connection: AzureBlobConnection,
  objectName: string
): Promise<{ blob: BlockBlobClientInstance; credential: SharedKeyCredentialInstance }> {
  const { service, credential } = await getClient(connection)
  const blob = service.getContainerClient(connection.bucket).getBlockBlobClient(objectName)
  return { blob, credential }
}

/**
 * Clock skew allowance on a SAS start time.
 *
 * Without it, a signed URL handed to a browser whose clock — or whose CDN's
 * clock — runs a little ahead of the signing host is rejected as not-yet-valid.
 * Five minutes matches the presigner behaviour operators already expect and is
 * far below any TTL this application mints.
 */
const SAS_CLOCK_SKEW_MS = 5 * 60 * 1000

/**
 * The protocol restriction to stamp on a SAS.
 *
 * Derived from the endpoint rather than fixed, and that distinction is load
 * bearing: a SAS signed `https`-only is refused with a 403 when the URL is then
 * fetched over `http`, which is every Azurite install and any private-link or
 * proxied endpoint an operator has deliberately configured as plaintext.
 * Hardcoding `Https` made local development fail in a way that looks exactly
 * like a credential problem — measured against Azurite, not reasoned about.
 *
 * The default is still the strict one. Real Azure accounts are reached over
 * `https`, so a production deployment gets an HTTPS-only SAS without opting in;
 * only an endpoint the operator has explicitly written as `http://` widens it.
 */
function sasProtocol(connection: AzureBlobConnection, module: AzureBlobModule): string {
  return resolveEndpoint(connection).startsWith('http://')
    ? module.SASProtocol.HttpsAndHttp
    : module.SASProtocol.Https
}

/**
 * Build the Azure Blob implementation of the wire operations.
 *
 * `connection` is captured by the caller at construction time and never re-read,
 * which is what binds a client to the scope that built it.
 */
export function createAzureBlobOperations(connection: AzureBlobConnection): AzureBlobOperations {
  return {
    /**
     * A SAS URL a client may PUT to.
     *
     * **Unused by this application today** — browsers upload through the
     * same-origin `/api/storage` proxy, so nothing mints a direct upload URL.
     * Implemented anyway because it is part of the interface, and noted because
     * an Azure caveat applies the moment it *is* used: a direct PUT to a blob
     * SAS URL must carry the `x-ms-blob-type: BlockBlob` header. Azure rejects
     * the request without it, and no S3 client sends it. Any future direct-upload
     * path must add that header for this driver.
     */
    async presignPut(objectName, contentType, expiresIn) {
      const { blob, credential } = await getBlob(connection, objectName)
      const azure = await getAzureModule()
      const { BlobSASPermissions, generateBlobSASQueryParameters } = azure
      const sas = generateBlobSASQueryParameters(
        {
          containerName: connection.bucket,
          blobName: objectName,
          // create + write: a block blob PUT needs both.
          permissions: BlobSASPermissions.parse('cw'),
          startsOn: new Date(Date.now() - SAS_CLOCK_SKEW_MS),
          expiresOn: new Date(Date.now() + expiresIn * 1000),
          contentType,
          protocol: sasProtocol(connection, azure),
        },
        credential
      ).toString()
      return `${blob.url}?${sas}`
    },

    async put(objectName, body, contentType) {
      const { blob } = await getBlob(connection, objectName)
      await blob.uploadData(Buffer.isBuffer(body) ? body : Buffer.from(body), {
        blobHTTPHeaders: { blobContentType: contentType },
      })
    },

    async get(objectName) {
      const { blob } = await getBlob(connection, objectName)
      const response = await blob.download()
      if (!response.readableStreamBody) {
        throw new Error(`Storage object not found: ${objectName}`)
      }
      return {
        // The SDK yields a Node stream on this runtime; the callers — the
        // /api/storage proxy and the export download — return a web stream in a
        // Response, so convert here rather than at each call site.
        //
        // Through `unknown`: `Readable.toWeb` is typed against the
        // `node:stream/web` ReadableStream, which is structurally distinct from
        // the global DOM one the callers expect even though it is the same
        // object at runtime.
        body: Readable.toWeb(
          Readable.from(response.readableStreamBody)
        ) as unknown as ReadableStream<Uint8Array>,
        contentType: response.contentType || 'application/octet-stream',
      }
    },

    async presignGet(objectName, expiresIn, downloadName) {
      const { blob, credential } = await getBlob(connection, objectName)
      const azure = await getAzureModule()
      const { BlobSASPermissions, generateBlobSASQueryParameters } = azure
      const sas = generateBlobSASQueryParameters(
        {
          containerName: connection.bucket,
          blobName: objectName,
          permissions: BlobSASPermissions.parse('r'),
          startsOn: new Date(Date.now() - SAS_CLOCK_SKEW_MS),
          expiresOn: new Date(Date.now() + expiresIn * 1000),
          // Azure's rscd, the equivalent of S3's ResponseContentDisposition.
          ...(downloadName
            ? { contentDisposition: `attachment; filename="${downloadName}"` }
            : {}),
          protocol: sasProtocol(connection, azure),
        },
        credential
      ).toString()
      return `${blob.url}?${sas}`
    },

    /**
     * Delete, tolerating an already-absent blob.
     *
     * `deleteIfExists` rather than `delete` so the operation matches S3's
     * `DeleteObjectCommand`, which succeeds on a missing key. A driver that
     * threw here would turn every idempotent cleanup path in the application
     * into a backend-specific failure.
     */
    async remove(objectName) {
      const { blob } = await getBlob(connection, objectName)
      await blob.deleteIfExists()
    },
  }
}

/** Test seam — the module and client caches would otherwise leak across cases. */
export function __resetAzureBlobCachesForTests(): void {
  _azureModule = null
  blobClients.clear()
}
