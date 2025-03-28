@description('The location used for all deployed resources')
param location string = resourceGroup().location

@description('Tags that will be applied to all resources')
param tags object = {}


param loadItExists bool
param aiFoundryProjectConnectionString string

@description('Id of the user or app to assign application roles')
param principalId string

var abbrs = loadJsonContent('./abbreviations.json')
var resourceToken = uniqueString(subscription().id, resourceGroup().id, location)

// Monitor application with Azure Monitor
module monitoring 'br/public:avm/ptn/azd/monitoring:0.1.0' = {
  name: 'monitoring'
  params: {
    logAnalyticsName: '${abbrs.operationalInsightsWorkspaces}${resourceToken}'
    applicationInsightsName: '${abbrs.insightsComponents}${resourceToken}'
    applicationInsightsDashboardName: '${abbrs.portalDashboards}${resourceToken}'
    location: location
    tags: tags
  }
}

// Container registry
module containerRegistry 'br/public:avm/res/container-registry/registry:0.1.1' = {
  name: 'registry'
  params: {
    name: '${abbrs.containerRegistryRegistries}${resourceToken}'
    location: location
    tags: tags
    publicNetworkAccess: 'Enabled'
    roleAssignments:[
      {
        principalId: loadItIdentity.outputs.principalId
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
      }
    ]
  }
}

// Container apps environment
module containerAppsEnvironment 'br/public:avm/res/app/managed-environment:0.4.5' = {
  name: 'container-apps-environment'
  params: {
    logAnalyticsWorkspaceResourceId: monitoring.outputs.logAnalyticsWorkspaceResourceId
    name: '${abbrs.appManagedEnvironments}${resourceToken}'
    location: location
    zoneRedundant: false
  }
}

module loadItIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.2.1' = {
  name: 'loadItidentity'
  params: {
    name: '${abbrs.managedIdentityUserAssignedIdentities}loadIt-${resourceToken}'
    location: location
  }
}

module loadItFetchLatestImage './modules/fetch-container-image.bicep' = {
  name: 'loadIt-fetch-image'
  params: {
    exists: loadItExists
    name: 'load-it'
  }
}

module loadIt 'br/public:avm/res/app/container-app:0.8.0' = {
  name: 'loadIt'
  params: {
    name: 'load-it'
    ingressTargetPort: 5050
    scaleMinReplicas: 1
    scaleMaxReplicas: 10
    secrets: {
      secureList:  [
        {
          name: 'redis-pass'
          identity:loadItIdentity.outputs.resourceId
          keyVaultUrl: '${keyVault.outputs.uri}secrets/redis-password'
        }
        {
          name: 'redis-url'
          identity:loadItIdentity.outputs.resourceId
          keyVaultUrl: '${keyVault.outputs.uri}secrets/redis-url'
        }
      ]
    }
    containers: [
      {
        image: loadItFetchLatestImage.outputs.?containers[?0].?image ?? 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
        name: 'main'
        resources: {
          cpu: json('0.5')
          memory: '1.0Gi'
        }
        env: [
          {
            name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
            value: monitoring.outputs.applicationInsightsConnectionString
          }
          {
            name: 'AZURE_CLIENT_ID'
            value: loadItIdentity.outputs.clientId
          }
          {
            name: 'REDIS_HOST'
            value: redis.outputs.hostName
          }
          {
            name: 'REDIS_PORT'
            value: string(redis.outputs.sslPort)
          }
          {
            name: 'REDIS_ENDPOINT'
            value: '${redis.outputs.hostName}:${string(redis.outputs.sslPort)}'
          }
          {
            name: 'REDIS_URL'
            secretRef: 'redis-url'
          }
          {
            name: 'REDIS_PASSWORD'
            secretRef: 'redis-pass'
          }
          {
            name: 'AZURE_KEY_VAULT_NAME'
            value: keyVault.outputs.name
          }
          {
            name: 'AZURE_KEY_VAULT_ENDPOINT'
            value: keyVault.outputs.uri
          }
          {
            name: 'AZURE_AIPROJECT_CONNECTION_STRING'
            value: aiFoundryProjectConnectionString
          }
          {
            name: 'PORT'
            value: '5050'
          }
        ]
      }
    ]
    managedIdentities:{
      systemAssigned: false
      userAssignedResourceIds: [loadItIdentity.outputs.resourceId]
    }
    registries:[
      {
        server: containerRegistry.outputs.loginServer
        identity: loadItIdentity.outputs.resourceId
      }
    ]
    environmentResourceId: containerAppsEnvironment.outputs.resourceId
    location: location
    tags: union(tags, { 'azd-service-name': 'load-it' })
  }
}

resource loadItbackendRoleAzureAIDeveloperRG 'Microsoft.Authorization/roleAssignments@2020-04-01-preview' = {
  name: guid(subscription().id, resourceGroup().id, loadItIdentity.name, '64702f94-c441-49e6-a78b-ef80e0188fee')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '64702f94-c441-49e6-a78b-ef80e0188fee') 
    principalId: loadItIdentity.outputs.principalId
    principalType: 'ServicePrincipal'
  }
}
module redis 'br/public:avm/res/cache/redis:0.9.0' = {
  name: 'redisDeployment'
  params: {
    // Required parameters
    name: '${abbrs.cacheRedis}${resourceToken}'
    // Non-required parameters
    location: location
    skuName: 'Basic'
    secretsExportConfiguration: {
      keyVaultResourceId: keyVault.outputs.resourceId
      primaryAccessKeyName: 'redis-password'
      primaryConnectionStringName: 'redis-url'
    }
  }
}
// Create a keyvault to store secrets
module keyVault 'br/public:avm/res/key-vault/vault:0.12.0' = {
  name: 'keyvault'
  params: {
    name: '${abbrs.keyVaultVaults}${resourceToken}'
    location: location
    tags: tags
    enableRbacAuthorization: false
    accessPolicies: [
      {
        objectId: principalId
        permissions: {
          secrets: [ 'get', 'list', 'set' ]
        }
      }
      {
        objectId: loadItIdentity.outputs.principalId
        permissions: {
          secrets: [ 'get', 'list' ]
        }
      }
    ]
    secrets: [
    ]
  }
}
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = containerRegistry.outputs.loginServer
output AZURE_RESOURCE_LOAD_IT_ID string = loadIt.outputs.resourceId
output AZURE_KEY_VAULT_ENDPOINT string = keyVault.outputs.uri
output AZURE_KEY_VAULT_NAME string = keyVault.outputs.name
output AZURE_RESOURCE_VAULT_ID string = keyVault.outputs.resourceId
output AZURE_RESOURCE_REDIS_ID string = redis.outputs.resourceId
