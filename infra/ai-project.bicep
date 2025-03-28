
param gpt4oMini20240718Location string

@description('Tags that will be applied to all resources')
param tags object = {}

@description('Main location for the resources')
param location string

var abbrs = loadJsonContent('./abbreviations.json')
var resourceToken = uniqueString(subscription().id, resourceGroup().id, location)

@description('The name of the environment')
param envName string

module keyVault 'br/public:avm/res/key-vault/vault:0.6.1' = {
  name: 'keyvaultForHub'
  params: {
    name: '${abbrs.keyVaultVaults}hub${resourceToken}'
    location: location
    tags: tags
    enableRbacAuthorization: false
  }
}

module storage 'br/public:avm/res/storage/storage-account:0.17.2' = {
  name: 'storageAccountForHub'
  params: {
    tags: tags
    name: '${abbrs.storageStorageAccounts}hub${resourceToken}'
    allowSharedKeyAccess: true
    allowBlobPublicAccess: true
    allowCrossTenantReplication: true
    largeFileSharesState: 'Disabled'
    publicNetworkAccess: 'Enabled'
    location: location
    blobServices: {
      containers: [
        {
          name: 'default'
        }
      ]
    }
    fileServices: {
      shares: [
        {
          name: 'default'
        }
      ]
    }
    queueServices: {
      queues: [
        {
          name: 'default'
        }
      ]
    }
    tableServices: {
      tables: [
        {
          name: 'default'
        }
      ]
    }
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
    }
  }
}
resource gpt4oMini20240718Deploy 'Microsoft.CognitiveServices/accounts@2023-05-01' = {
  name: 'gpt4oMini20240718${resourceToken}'
  location: gpt4oMini20240718Location
  tags: tags
  sku: {
    name: 'S0'
  }
  kind: 'AIServices'
  properties: {
    apiProperties: {
      statisticsEnabled: false
    }
  }
  
  resource deployment 'deployments' = {
    name: 'gpt-4o-mini'
    properties: {
      model: {
        name: 'gpt-4o-mini'
        format: 'OpenAI'
        version: '2024-07-18'
      }
    }
    sku: {
      name: 'GlobalStandard'
      capacity: 10
    }
  }
}

resource hub 'Microsoft.MachineLearningServices/workspaces@2024-10-01' = {
  name: take('${envName}${resourceToken}',32)
  location: location
  tags: tags
  kind: 'Hub'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    friendlyName: envName
    storageAccount: storage.outputs.resourceId
    keyVault: keyVault.outputs.resourceId
    hbiWorkspace: false
    managedNetwork: {
      isolationMode: 'Disabled'
    }
    v1LegacyMode: false
    publicNetworkAccess: 'Enabled'
  }
  resource gpt4oMini20240718connection 'connections' = {
    name: 'gpt4oMini20240718-connection'
    properties: {
      category: 'AIServices'
      target: gpt4oMini20240718Deploy.properties.endpoint
      authType: 'ApiKey'
      isSharedToAll: true
      credentials: {
        key: gpt4oMini20240718Deploy.listKeys().key1
      }
      metadata: {
        ApiType: 'Azure'
        ResourceId: gpt4oMini20240718Deploy.id
      }
    }
  }
}

resource project 'Microsoft.MachineLearningServices/workspaces@2024-10-01' = {
  name: envName
  location: location
  tags: tags
  sku: {
    name: 'Basic'
    tier: 'Basic'
  }
  kind: 'Project'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    friendlyName: '${envName}Proj'
    hbiWorkspace: false
    v1LegacyMode: false
    publicNetworkAccess: 'Enabled'
    hubResourceId: hub.id
  }
}

resource mlServiceRoleDataScientist 'Microsoft.Authorization/roleAssignments@2020-04-01-preview' = {
  name: guid(subscription().id, resourceGroup().id, project.id, 'mlServiceRoleDataScientist', 'f6c7c914-8db3-469d-8ca1-694a8f32e121')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'f6c7c914-8db3-469d-8ca1-694a8f32e121')
    principalId: project.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource mlServiceRoleSecretsReader 'Microsoft.Authorization/roleAssignments@2020-04-01-preview' = {
  name: guid(subscription().id, resourceGroup().id, project.id, 'mlServiceRoleSecretsReader','ea01e6af-a1c1-4350-9563-ad00f8c72ec5')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ea01e6af-a1c1-4350-9563-ad00f8c72ec5') 
    principalId: project.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

output hubName string = hub.name
output projectDiscoveryUrl string = project.properties.discoveryUrl
output projectId string = project.id
output projectName string = project.name
output aiFoundryProjectConnectionString string = '${split(project.properties.discoveryUrl, '/')[2]};${subscription().subscriptionId};${resourceGroup().name};${project.name}'

