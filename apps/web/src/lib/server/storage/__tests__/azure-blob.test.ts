/**
 * The Azure Blob driver, observed where it matters: at the blob client.
 *
 * Same discipline as `workspace-scoped-client.test.ts`, and for the same reason.
 * Asserting that the driver returns a plausible object would only prove this
 * module agrees with itself. The fact that decides whether one customer reads
 * another's files is the **blob name** that reaches `getBlockBlobClient`, so
 * every assertion below is about a call this test caused, the capture is
 * cleared before each case, and a refusal is asserted as "no blob was
 * addressed", never as "the call threw".
 *
 * The switch is exercised through the *public* storage API rather than by
 * calling `createAzureBlobOperations` directly, because the property worth
 * holding is not "the driver works" but "the driver is reached with names the
 * namespacing rules already validated".
 */
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { workspaceIdFor } from '@/lib/server/__tests__/workspace-scope'

const mockConfig = {
  storageDriver: 'azure_blob' as 's3' | 'azure_blob',
  s3Bucket: 'env-container',
  // Deliberately absent: Azure has no region, and the driver must not require
  // one. A test that set it would hide exactly the operator trap the
  // placeholder-region code exists to avoid.
  s3Region: undefined as string | undefined,
  s3Endpoint: undefined as string | undefined,
  s3AccessKeyId: 'envaccount',
  s3SecretAccessKey: 'env-account-key',
  s3ForcePathStyle: true,
  s3PublicUrl: undefined as string | undefined,
  s3Proxy: false,
  baseUrl: 'https://env-app.example.net',
}
vi.mock('@/lib/server/config', () => ({ config: mockConfig }))

const findFirst = vi.fn(async () => ({ id: 'workspace_01kzf9848he8h86ct48hanask6' }))
vi.mock('@/lib/server/db', () => ({
  db: { query: { settings: { findFirst: () => findFirst() } } },
}))

/** Every blob addressed in this test, with the container and account it went through. */
const addressed: Array<{ container: string; blob: string; account: string; endpoint: string }> = []
/** Every upload that reached the wire. */
const uploads: Array<{ blob: string; contentType?: string; bytes: number }> = []
/** Every delete that reached the wire. */
const deletes: string[] = []
/** Every SAS minted, with the options it was built from. */
const sasCalls: Array<{
  containerName: string
  blobName: string
  permissions: string
  contentDisposition?: string
  expiresOn: Date
  startsOn?: Date
  protocol?: string
}> = []
/** Credentials each service client was constructed with. */
const clientCredentials: Array<{ account: string; key: string }> = []

vi.mock('@azure/storage-blob', () => ({
  StorageSharedKeyCredential: vi.fn(function (accountName: string, accountKey: string) {
    clientCredentials.push({ account: accountName, key: accountKey })
    return { accountName, accountKey }
  }),
  BlobServiceClient: vi.fn(function (url: string, credential: { accountName: string }) {
    return {
      getContainerClient: (containerName: string) => ({
        getBlockBlobClient: (blobName: string) => {
          addressed.push({
            container: containerName,
            blob: blobName,
            account: credential.accountName,
            endpoint: url,
          })
          return {
            url: `${url}/${containerName}/${blobName}`,
            uploadData: async (
              data: Buffer,
              options?: { blobHTTPHeaders?: { blobContentType?: string } }
            ) => {
              uploads.push({
                blob: blobName,
                contentType: options?.blobHTTPHeaders?.blobContentType,
                bytes: data.length,
              })
            },
            download: async () => ({
              readableStreamBody: (await import('node:stream')).Readable.from([
                Buffer.from('blob-bytes'),
              ]),
              contentType: 'image/png',
            }),
            deleteIfExists: async () => {
              deletes.push(blobName)
              return { succeeded: true }
            },
          }
        },
      }),
    }
  }),
  BlobSASPermissions: {
    parse: (permissions: string) => ({ toString: () => permissions }),
  },
  generateBlobSASQueryParameters: vi.fn(
    (
      options: {
        containerName: string
        blobName: string
        permissions: { toString(): string }
        contentDisposition?: string
        expiresOn: Date
        startsOn?: Date
      },
      _credential: unknown
    ) => {
      sasCalls.push({ ...options, permissions: options.permissions.toString() })
      return { toString: () => 'sig=stub-sas' }
    }
  ),
  SASProtocol: { Https: 'https', HttpsAndHttp: 'https,http' },
}))

/** The S3 SDK must stay untouched under this driver — asserted, not assumed. */
const s3Sends: unknown[] = []
vi.mock('@aws-sdk/client-s3', () => ({
  S3Client: vi.fn(function () {
    return {
      send: async (command: unknown) => {
        s3Sends.push(command)
        return {}
      },
      destroy: vi.fn(),
    }
  }),
  PutObjectCommand: vi.fn(function (input: unknown) {
    return { input }
  }),
  GetObjectCommand: vi.fn(function (input: unknown) {
    return { input }
  }),
  DeleteObjectCommand: vi.fn(function (input: unknown) {
    return { input }
  }),
}))
vi.mock('@aws-sdk/s3-request-presigner', () => ({
  getSignedUrl: vi.fn(async () => 'https://s3.example.com/should-not-be-used'),
}))

const {
  deleteObject,
  generatePresignedGetUrl,
  getS3Object,
  isS3Configured,
  uploadObject,
} = await import('../s3')
const { StorageNamespaceViolation, WORKSPACE_NAMESPACE_ROOT } = await import('../namespace')
const { __resetAzureBlobCachesForTests } = await import('../azure-blob')
const { withWorkspace } = await import('@/lib/server/__tests__/workspace-scope')

const PUBLIC_KEY = 'logos/2026/08/brand.png'
const PRIVATE_KEY = 'attachments/2026/08/contract.pdf'
const BYTES = Buffer.from([1, 2, 3])

const nameFor = (workspaceKey: string, key: string) =>
  `${WORKSPACE_NAMESPACE_ROOT}/${workspaceIdFor(workspaceKey)}/${key}`

beforeEach(() => {
  addressed.length = 0
  uploads.length = 0
  deletes.length = 0
  sasCalls.length = 0
  clientCredentials.length = 0
  s3Sends.length = 0
  mockConfig.storageDriver = 'azure_blob'
  mockConfig.s3Endpoint = undefined
  mockConfig.s3Region = undefined
  // The client cache is keyed by connection parameters, which several cases
  // below vary; without this a later case reuses an earlier case's endpoint.
  __resetAzureBlobCachesForTests()
})

describe('the driver switch', () => {
  it('routes writes to Azure and leaves the S3 SDK untouched', async () => {
    await withWorkspace('workspace-alpha', () => uploadObject(PUBLIC_KEY, BYTES, 'image/png'))

    expect(uploads).toHaveLength(1)
    expect(s3Sends).toHaveLength(0)
  })

  it('routes to S3 when the driver is not azure_blob', async () => {
    mockConfig.storageDriver = 's3'
    mockConfig.s3Region = 'us-east-1'

    await withWorkspace('workspace-alpha', () => uploadObject(PUBLIC_KEY, BYTES, 'image/png'))

    expect(s3Sends).toHaveLength(1)
    expect(uploads).toHaveLength(0)
  })
})

describe('every blob name is namespaced', () => {
  it('writes into the calling workspace namespace', async () => {
    await withWorkspace('workspace-alpha', () => uploadObject(PUBLIC_KEY, BYTES, 'image/png'))

    expect(addressed).toHaveLength(1)
    expect(addressed[0]!.blob).toBe(nameFor('workspace-alpha', PUBLIC_KEY))
    expect(addressed[0]!.container).toBe('workspace-alpha-bucket')
  })

  it('reads, presigns and deletes through the same namespace', async () => {
    await withWorkspace('workspace-alpha', () => getS3Object(PUBLIC_KEY))
    await withWorkspace('workspace-alpha', () => deleteObject(PUBLIC_KEY))
    await withWorkspace('workspace-alpha', () => generatePresignedGetUrl(PUBLIC_KEY, 60))

    const expected = nameFor('workspace-alpha', PUBLIC_KEY)
    expect(addressed.map((a) => a.blob)).toEqual([expected, expected, expected])
  })

  it('keeps two workspaces in one container apart', async () => {
    await withWorkspace('workspace-alpha', () => uploadObject(PUBLIC_KEY, BYTES, 'image/png'))
    await withWorkspace('workspace-beta', () => uploadObject(PUBLIC_KEY, BYTES, 'image/png'))

    expect(addressed[0]!.blob).toBe(nameFor('workspace-alpha', PUBLIC_KEY))
    expect(addressed[1]!.blob).toBe(nameFor('workspace-beta', PUBLIC_KEY))
    expect(addressed[0]!.blob).not.toBe(addressed[1]!.blob)
  })

  /**
   * The refusal is asserted as "nothing was addressed", not as "it threw". A
   * driver that threw *after* handing a traversal name to the SDK would pass
   * the weaker assertion.
   */
  it('refuses a traversal key without addressing a blob', async () => {
    await expect(
      withWorkspace('workspace-alpha', () => uploadObject('../other/x.png', BYTES, 'image/png'))
    ).rejects.toBeInstanceOf(StorageNamespaceViolation)

    expect(addressed).toHaveLength(0)
    expect(uploads).toHaveLength(0)
  })
})

describe('the wire operations', () => {
  it('carries the content type onto the blob headers', async () => {
    await withWorkspace('workspace-alpha', () => uploadObject(PUBLIC_KEY, BYTES, 'image/png'))

    expect(uploads[0]!.contentType).toBe('image/png')
    expect(uploads[0]!.bytes).toBe(BYTES.length)
  })

  it('returns a web stream and the blob content type', async () => {
    const result = await withWorkspace('workspace-alpha', () => getS3Object(PUBLIC_KEY))

    expect(result.contentType).toBe('image/png')
    expect(result.body).toBeInstanceOf(ReadableStream)
    const text = await new Response(result.body).text()
    expect(text).toBe('blob-bytes')
  })

  /**
   * S3's DeleteObjectCommand succeeds on a missing key, so the Azure driver
   * must use `deleteIfExists`. A plain `delete` would turn every idempotent
   * cleanup path in the application into a backend-specific failure.
   */
  it('deletes idempotently', async () => {
    await withWorkspace('workspace-alpha', () => deleteObject(PRIVATE_KEY))

    expect(deletes).toEqual([nameFor('workspace-alpha', PRIVATE_KEY)])
  })
})

describe('SAS generation', () => {
  it('mints a read SAS scoped to the namespaced blob', async () => {
    const url = await withWorkspace('workspace-alpha', () =>
      generatePresignedGetUrl(PUBLIC_KEY, 60)
    )

    expect(sasCalls).toHaveLength(1)
    expect(sasCalls[0]!.permissions).toBe('r')
    expect(sasCalls[0]!.blobName).toBe(nameFor('workspace-alpha', PUBLIC_KEY))
    expect(url).toContain('sig=stub-sas')
  })

  it('sets a content disposition when a download name is given', async () => {
    await withWorkspace('workspace-alpha', () =>
      generatePresignedGetUrl(PRIVATE_KEY, 60, 'contract.pdf')
    )

    expect(sasCalls[0]!.contentDisposition).toBe('attachment; filename="contract.pdf"')
  })

  it('omits the content disposition when no download name is given', async () => {
    await withWorkspace('workspace-alpha', () => generatePresignedGetUrl(PRIVATE_KEY, 60))

    expect(sasCalls[0]!.contentDisposition).toBeUndefined()
  })

  /**
   * A SAS whose validity begins at the signing instant is rejected as
   * not-yet-valid by any client whose clock runs even slightly ahead.
   */
  it('backdates the start time to absorb clock skew', async () => {
    await withWorkspace('workspace-alpha', () => generatePresignedGetUrl(PUBLIC_KEY, 60))

    expect(sasCalls[0]!.startsOn!.getTime()).toBeLessThan(Date.now())
  })

  it('honours the requested expiry', async () => {
    const before = Date.now()
    await withWorkspace('workspace-alpha', () => generatePresignedGetUrl(PUBLIC_KEY, 600))

    const expiry = sasCalls[0]!.expiresOn.getTime()
    expect(expiry).toBeGreaterThanOrEqual(before + 600 * 1000)
  })

  /**
   * Regression, measured against Azurite: a SAS signed https-only is refused
   * with a 403 when the URL is fetched over http, which is every emulator and
   * every deliberately-plaintext endpoint. The strict default still applies to
   * the https endpoints real Azure accounts use.
   */
  it('restricts a SAS to https for an https endpoint', async () => {
    await uploadObject(PUBLIC_KEY, BYTES, 'image/png')
    await generatePresignedGetUrl(PUBLIC_KEY, 60)

    expect(sasCalls[0]!.protocol).toBe('https')
  })

  it('permits http for an explicitly plaintext endpoint', async () => {
    mockConfig.s3Endpoint = 'http://127.0.0.1:10000/devstoreaccount1'

    await generatePresignedGetUrl(PUBLIC_KEY, 60)

    expect(sasCalls[0]!.protocol).toBe('https,http')
  })
})

describe('endpoint resolution', () => {
  /**
   * Unscoped is the shape every self-hosted and single-workspace Azure install
   * runs in: no workspace record, connection read from the environment.
   */
  it('derives the public-cloud endpoint from the account name', async () => {
    await uploadObject(PUBLIC_KEY, BYTES, 'image/png')

    expect(addressed[0]!.endpoint).toBe('https://envaccount.blob.core.windows.net')
    expect(addressed[0]!.container).toBe('env-container')
  })

  it('prefers an explicit endpoint, for Azurite and private link', async () => {
    mockConfig.s3Endpoint = 'http://127.0.0.1:10000/devstoreaccount1'

    await uploadObject(PUBLIC_KEY, BYTES, 'image/png')

    expect(addressed[0]!.endpoint).toBe('http://127.0.0.1:10000/devstoreaccount1')
  })

  it('strips a trailing slash so the blob URL does not double up', async () => {
    mockConfig.s3Endpoint = 'https://custom.example.com/'

    await uploadObject(PUBLIC_KEY, BYTES, 'image/png')

    expect(addressed[0]!.endpoint).toBe('https://custom.example.com')
  })

  it('signs with the account name and key from the environment', async () => {
    await uploadObject(PUBLIC_KEY, BYTES, 'image/png')

    expect(clientCredentials[0]).toEqual({ account: 'envaccount', key: 'env-account-key' })
  })
})

describe('configuration', () => {
  /**
   * The point of the placeholder region. An Azure operator has no value to put
   * in S3_REGION, so requiring it would gate storage on a variable that is
   * never read.
   */
  it('reports configured without a region under the azure driver', () => {
    expect(mockConfig.s3Region).toBeUndefined()
    expect(isS3Configured()).toBe(true)
  })

  it('still requires a region under the s3 driver', () => {
    mockConfig.storageDriver = 's3'

    expect(isS3Configured()).toBe(false)
  })

  it('reports unconfigured when the container is missing', () => {
    const bucket = mockConfig.s3Bucket
    mockConfig.s3Bucket = ''
    try {
      expect(isS3Configured()).toBe(false)
    } finally {
      mockConfig.s3Bucket = bucket
    }
  })
})
