// ============================================================================
// Quackback — Azure VM deployment (Bicep)
// ============================================================================
// Provisions a single Ubuntu VM that self-hosts Quackback via
// docker-compose.prod.yml (app + Postgres + Dragonfly + MinIO) with Caddy in
// front for automatic HTTPS. Everything is bootstrapped by cloud-init.yaml.
//
// Deploy into an EXISTING resource group:
//   az deployment group create \
//     --resource-group <your-rg> \
//     --template-file main.bicep \
//     --parameters @main.parameters.example.json \
//     --parameters adminSshPublicKey="$(cat ~/.ssh/id_ed25519.pub)"
//
// See deploy/azure/README.md for the full walkthrough.
// ============================================================================

@description('Azure region for all resources. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('DNS label prefix for the public IP. The site FQDN becomes <prefix>.<region>.cloudapp.azure.com. Must be globally unique within the region.')
param dnsLabelPrefix string

@description('Admin username for SSH access to the VM.')
param adminUsername string = 'azureuser'

@description('SSH public key used to log in to the VM (password auth is disabled).')
@secure()
param adminSshPublicKey string

@description('CIDR/IP allowed to reach SSH (port 22). Set to your office/home IP for safety, e.g. 203.0.113.4/32. Defaults to Internet — tighten this!')
param sshSourceAddressPrefix string = 'Internet'

@description('VM size. B2s (2 vCPU / 4 GB) suits intern testing; use B2ms (8 GB) if AI features are enabled.')
param vmSize string = 'Standard_B2s'

@description('Published Quackback image tag to run (pin to a release in production, e.g. 0.10.6).')
param quackbackTag string = 'latest'

@description('Email address used by Caddy/Let\'s Encrypt for TLS certificate registration.')
param acmeEmail string

@description('Session signing/encryption key (>= 32 chars). Leave as default to auto-generate.')
@secure()
param secretKey string = '${newGuid()}${newGuid()}'

@description('PostgreSQL password. Leave as default to auto-generate.')
@secure()
param postgresPassword string = newGuid()

@description('MinIO root password (doubles as the S3 secret). Leave as default to auto-generate.')
@secure()
param minioPassword string = newGuid()

@description('SMTP host for outbound email (invites, magic-link login). Leave blank to log emails to the container console.')
param emailSmtpHost string = ''

@description('SMTP port.')
param emailSmtpPort string = '587'

@description('SMTP username.')
param emailSmtpUser string = ''

@description('SMTP password.')
@secure()
param emailSmtpPass string = ''

@description('From address for outbound email.')
param emailFrom string = 'Quackback <noreply@example.com>'

// --- Derived values ---------------------------------------------------------

// Azure guarantees this FQDN format for a public IP with a DNS label, so we can
// build BASE_URL/DOMAIN up front without a circular dependency on the IP resource.
var fqdn = '${dnsLabelPrefix}.${location}.cloudapp.azure.com'
var baseUrl = 'https://${fqdn}'

var namePrefix = 'quackback'

// Render cloud-init: load the template and substitute deploy-time values.
var cloudInit = replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(loadTextContent('cloud-init.yaml'), '__BASE_URL__', baseUrl), '__DOMAIN__', fqdn), '__ACME_EMAIL__', acmeEmail), '__SECRET_KEY__', secretKey), '__QUACKBACK_TAG__', quackbackTag), '__POSTGRES_PASSWORD__', postgresPassword), '__MINIO_PASSWORD__', minioPassword), '__EMAIL_SMTP_HOST__', emailSmtpHost), '__EMAIL_SMTP_PORT__', emailSmtpPort), '__EMAIL_SMTP_USER__', emailSmtpUser), '__EMAIL_SMTP_PASS__', emailSmtpPass), '__EMAIL_FROM__', emailFrom)

// --- Networking -------------------------------------------------------------

resource nsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: '${namePrefix}-nsg'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowSSH'
        properties: {
          priority: 1000
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: sshSourceAddressPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
      }
      {
        name: 'AllowHTTP'
        properties: {
          priority: 1010
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '80'
        }
      }
      {
        name: 'AllowHTTPS'
        properties: {
          priority: 1020
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: '${namePrefix}-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.0.0.0/16'
      ]
    }
    subnets: [
      {
        name: 'default'
        properties: {
          addressPrefix: '10.0.0.0/24'
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
    ]
  }
}

resource publicIp 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: '${namePrefix}-pip'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: dnsLabelPrefix
    }
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: '${namePrefix}-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: vnet.properties.subnets[0].id
          }
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: {
            id: publicIp.id
          }
        }
      }
    ]
  }
}

// --- Virtual machine --------------------------------------------------------

resource vm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: '${namePrefix}-vm'
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: '${namePrefix}-vm'
      adminUsername: adminUsername
      customData: base64(cloudInit)
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: adminSshPublicKey
            }
          ]
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: 'server'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
        diskSizeGB: 64
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
  }
}

// --- Outputs ----------------------------------------------------------------

@description('Public HTTPS URL of the Quackback instance (also its BASE_URL).')
output baseUrl string = baseUrl

@description('Fully-qualified domain name of the VM.')
output fqdn string = fqdn

@description('SSH command to connect to the VM.')
output sshCommand string = 'ssh ${adminUsername}@${fqdn}'
