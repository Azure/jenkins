# Canary Deployment for Virtual Machine Scale Sets (VMSS)

Canary deployment is a pattern that rolls out releases to a subset of users or servers. It deploys the changes to a
small set of servers, which allows you to test and monitor how the new release works before rolling the changes to the
rest of the servers.

Virtual machine scale sets (VMSS) are an Azure compute resource that you can use to deploy and manage a set of identical VMs. 
With all VMs configured the same, scale sets are designed to support true autoscale, and no pre-provisioning of VMs 
is required. So it's easier to build large-scale services that target big compute, large data, and containerized workloads.

VMSS allow you to manage large number of identical VMs with simple instructions, yet allow you to update specific VMs. You can build your VMSS with a customized image or publicly available OS images along with VM extension scripts to setup all required environments. When it comes to update existing VMSS, you need to update its configuration with a new image or extension scripts, and then manually trigger the update of the VMSS instances, either all in one instruction, or selectively pick some VMs to be updated.

The ability to update individual VMs in VMSS allows us to control the number of VMs that will be updated to the new releases,
i.e., allows us to do canary deployment:

1. (Existing) Create the initial VMSS which host your services.
1. Update the VMSS configuration, either point to new customized image, or update the extension scripts, which contains the
   new release of your services.
1. Selectively update individual instances to the new release according to the configuration changes.
1. Verify the new release works.
1. Update the rest of instances to the new release.

## Nginx Canary Deployment Example

Here we demonstrate the canary deployment for VMSS using the Nginx binary release.

### Prepare the VMSS

We use the public Ubuntu Server 16.04 LTS together with an extension script which installs the Nginx service to setup the
VMSS. In your project, you can customize the extension script to install the service on demand, or create a customized
image (reference: [Packer / Azure Resource Manager Builder](https://www.packer.io/docs/builders/azure.html)).

#### Prepare variable configurations

First we setup some variables that will be used in the following preparation steps. You can update the variables based on your needs.

```sh
# resource group and VMSS name
resource_group=the-resource-group-name
location=the-resource-location
vmss_name=the-vmss-name

# admin user and SSH login credentials setup
admin_user=azureuser
ssh_pubkey="$(readlink -f ~/.ssh/id_rsa.pub)"

# the storage account that will be created to store the init scripts. Note that '-' is not allowed in a storage account name.
export AZURE_STORAGE_ACCOUNT=the-storage-account-name
```

#### Create VMSS from public Ubuntu image

We create a VMSS with 3 instances, using the public image "UbuntuLTS".

```sh
az group create --name "$resource_group" --location "$location"

# create the VMSS with 3 instances using the public Ubuntu LTS image
az vmss create --resource-group "$resource_group" --name "$vmss_name" \
    --image UbuntuLTS \
    --admin-username "$admin_user" \
    --ssh-key-value "$ssh_pubkey" \
    --vm-sku Standard_D2_v3 \
    --instance-count 3 \
    --lb "${vmss_name}LB"
```

#### Prepare the init scripts

In order to use the custom script extension to configure the VMSS, we need to store the script at some location that's accessible
via HTTP(s). Here we create a storage account for the script storage, and expose the scripts publicly to allow the script extension
to pick it up.

The custom script is fairly simple in this case. It installs the Nginx package from the Ubuntu Apt source. In your project,
you may update the script to fetch dependencies, install, configure and start services, etc.

```sh
# create the storage account and container that store the extension scripts
az storage account create --name "$AZURE_STORAGE_ACCOUNT" --location "$location" --resource-group "$resource_group" --sku Standard_LRS
export AZURE_STORAGE_KEY="$(az storage account keys list --resource-group "$resource_group" --account-name "$AZURE_STORAGE_ACCOUNT" --query '[0].value' --output tsv)"
az storage container create --name init --public-access container

# upload the init script to the blob container
cat <<EOF >install_nginx.sh
#!/bin/bash

sudo apt-get update
sudo apt-get install -y nginx
EOF
az storage blob upload --container-name init --file install_nginx.sh --name install_nginx.sh
init_script_url="$(az storage blob url --container-name init --name install_nginx.sh --output tsv)"
```

#### Install the custom script extension

```sh
# prepare the script config
cat <<EOF >script-config.json
{
  "fileUris": ["$init_script_url"],
  "commandToExecute": "./install_nginx.sh"
}
EOF
# install the CustomScript extension to the VMSS
az vmss extension set \
    --publisher Microsoft.Azure.Extensions \
    --version 2.0 \
    --name CustomScript \
    --resource-group "$resource_group" \
    --vmss-name "$vmss_name" \
    --settings @script-config.json
# update all the instances so that they will have nginx installed
az vmss update-instances --resource-group "$resource_group" --name "$vmss_name" --instance-ids \*
```

#### Update load balancer endpoint

We need to create a load balancer rule to route the public traffic to the Nginx services running in the VMSS
backend.

```sh
# create load balancer rule to allow public access to the backend Nginx service
az network lb probe create \
    --resource-group "$resource_group" \
    --lb-name "${vmss_name}LB" \
    --name nginx \
    --port 80 \
    --protocol Http \
    --path /

az network lb rule create \
    --resource-group "$resource_group" \
    --lb-name "${vmss_name}LB" \
    --name nginx \
    --frontend-port 80 \
    --backend-port 80 \
    --protocol Tcp \
    --backend-pool-name "${vmss_name}LBBEPool" \
    --probe nginx
```

#### Verify everything works

Check that we can access the Nginx service from the public endpoint of the load balancer.

```sh
# check that the Nginx service is working properly
lb_ip=$(az network lb show --resource-group "$resource_group" --name "${vmss_name}LB" --query "frontendIpConfigurations[].publicIpAddress.id" --output tsv | head -n1 | xargs az network public-ip show --query ipAddress --output tsv --ids)
curl -s "$lb_ip" | grep title
#>> <title>Welcome to nginx!</title>
```

### Deploy New Release in Canary Deployment Pattern

In the new release, we make a simple update in the Nginx landing page, and deploy it to 1 instance in the early stage. So after the
deployment, we should have 1 instance serving the updated landing page, and 2 instances serving the original page.

First, we need to update and upload the new custom script. Some points to call out here:

* The custom script will be executed on a fresh VM after it is created from the given OS image. It is not an incremental
   update process based on the existing VM. So we need to install all the dependencies and services again,
   with the changes in the new release included.
* Any updates you make to your application are not exposed to the Custom Script Extension unless that install script changes.
   To force VMSS to pick up the custom script changes, you need to change the script name so that it results in a different
   file URI.
* This will not affect the existing instances until we manually update those instances.

```sh
# prepare the updated nginx service
cat <<EOF >install_nginx.v1.sh
#!/bin/bash

sudo apt-get update
sudo apt-get install -y nginx
sudo sed -i -e 's/Welcome to nginx/Welcome to nginx on Azure VMSS/' /var/www/html/index*.html
EOF
az storage blob upload --container-name init --file install_nginx.v1.sh --name install_nginx.v1.sh
init_script_url="$(az storage blob url --container-name init --name install_nginx.v1.sh --output tsv)"

# prepare the script config
cat <<EOF >script-config.v1.json
{
  "fileUris": ["$init_script_url"],
  "commandToExecute": "./install_nginx.v1.sh"
}
EOF
# install the CustomScript extension to the VMSS
az vmss extension set \
    --publisher Microsoft.Azure.Extensions \
    --version 2.0 \
    --name CustomScript \
    --resource-group "$resource_group" \
    --vmss-name "$vmss_name" \
    --settings @script-config.v1.json
```

Now that the custom script configuration is update for the VMSS, we can update 1 instance to pick up the new custom script.

```sh
# pick up the first instance ID
instance_id="$(az vmss list-instances --resource-group "$resource_group" --name "$vmss_name" --query '[].instanceId' --output tsv | head -n1)"
# update the instance VM
az vmss update-instances --resource-group "$resource_group" --name "$vmss_name" --instance-ids "$instance_id"
# (optional) check the latest model applied status
az vmss list-instances --resource-group "$resource_group" --name "$vmss_name" | grep latest
#>>    "latestModelApplied": true,
#>>    "latestModelApplied": false,
#>>    "latestModelApplied": false,
```

Check the load balancer public endpoint and we should see the old version and new version interleaved.

```sh
curl -s "$lb_ip" | grep title
#>> <title>Welcome to nginx!</title>
curl -s "$lb_ip" | grep title
#>> <title>Welcome to nginx on Azure VMSS!</title>
curl -s "$lb_ip" | grep title
#>> <title>Welcome to nginx!</title>
curl -s "$lb_ip" | grep title
#>> <title>Welcome to nginx!</title>
```

Now you can do more checks to verify if the new version works as expected. Note that the VMSS sits behind the frontend
load balancer, **you do not know the service status for a individual node through the public access point**. If you need
to check a specific instance, you can SSH login to the that instance through the NAT mapping defined in the load balancer
and check the service in the SSH session; or you can open an tunnel to the remote service through the SSH channel,
and check the service in detail through the local port.

```sh
# obtain the NAT SSH port for the updated instance
ssh_port="$(az network lb inbound-nat-rule show --resource-group "$resource_group" --lb-name "${vmss_name}LB" --name "${vmss_name}LBNatPool.${instance_id}" --query frontendPort --output tsv)"
# map the localhost:8080 endpoint to the remote 80 port through the SSH channel
ssh -L localhost:8080:localhost:80 -p "$ssh_port" azureuser@"$lb_ip"
```

After this, you can visit the web page through `http://localhost:8080` and it will show you the page served by the updated instance.

### Complete the Release of the New Version

At this point you have 1 instance serving the updated web page and 2 instances serving the original page in the VMSS.
When you have verified that the new version works, you can update the rest of the instances to the new version.

```sh
az vmss update-instances --resource-group "$resource_group" --name "$vmss_name" --instance-ids \*
```

Note that this will update all the instances with models not aligned with the latest state in parallel. So all the outdated
instances will be brought down, updated, and brought up again. It will not cause service downtime as long as the load balancer noticed
some of the backends are down, as we have at least 1 instance updated in the previous steps. However, during the update window of
the outdated instances, all the client traffic will be routed to up-to-date instances, which will increase the load and latency
on those instances.

A better approach may be querying the outdated instances list first, and then update them with smaller granularity:

```sh
az vmss list-instances --resource-group "$resource_group" --name "$vmss_name" --query '[?latestModelApplied==`false`].instanceId' --output tsv
#>> 2
#>> 4
az vmss update-instances --resource-group "$resource_group" --name "$vmss_name" --instance-ids 2
# wait for instance 2 to be up and running
az vmss update-instances --resource-group "$resource_group" --name "$vmss_name" --instance-ids 4
```

In this way, only a small number of instances are being updated at a given point of time. The rest of the instances are not
touched and will serve the traffic as per normal.

### Work with Image Based Canary Deployment

The above steps demonstrates how we can do canary deployments for VMSS using the custom script extension. VMSS also supports
custom images. If specified, all the VMs will be created from the given image. Compared to the custom script extension based
VMSS, the image based VMSS:

* Provisions faster: the service creation and configuration is done at the image creation process, and when VMSS needs to provision
   new instance, it creates the VM from that image. It doesn't need to execute extra scripts after the VM provision. (Although you
   can still add a custom script extension if needed.)
* Service and dependency versions are more stable. The service and dependencies are fetched when the image is created, and all the
   VMs created from the image get the same binaries. If working with custom script extension, you need to be careful if the service
   or dependencies is upgraded when the VMSS is scaling.

[Packer](https://www.packer.io/docs/builders/azure.html) is widely used to create OS images in different cloud platforms. Consider
if we need to transform the above custom script extension based deployments to image based, we can create the base image using
the following packer configuration (filename: `packer-nginx.json`):

```json
{
    "variables": {
        "client_id": null,
        "client_secret": null,
        "subscription_id": null,
        "tenant_id": null,

        "resource_group": null,
        "location": null,

        "vm_size": "Standard_DS2_v2"
    },

    "builders": [
        {
            "type": "azure-arm",

            "client_id": "{{user `client_id`}}",
            "client_secret": "{{user `client_secret`}}",
            "subscription_id": "{{user `subscription_id`}}",
            "tenant_id": "{{user `tenant_id`}}",

            "managed_image_resource_group_name": "{{user `resource_group`}}",
            "managed_image_name": "nginx-base-image",

            "os_type": "Linux",
            "image_publisher": "Canonical",
            "image_offer": "UbuntuServer",
            "image_sku": "16.04-LTS",

            "location": "{{user `location`}}",
            "vm_size": "{{user `vm_size`}}"
        }
    ],

    "provisioners": [
        {
            "execute_command": "chmod +x {{ .Path }}; {{ .Vars }} sudo -E sh '{{ .Path }}'",
            "inline": [
                "apt-get update",
                "apt-get dist-upgrade -y",
                "apt-get install -y nginx",
                "/usr/sbin/waagent -force -deprovision+user && export HISTSIZE=0 && sync"
            ],
            "inline_shebang": "/bin/sh -x",
            "type": "shell"
        }
    ]
}
```

and build it with

```sh
packer build \
  -var "client_id=$your_service_principal_id" \
  -var "client_secret=$your_service_principal_key" \
  -var "subscription_id=$your_subscription_id" \
  -var "tenant_id=$your_tenant_id" \
  -var "resource_group=$resource_group" \
  -var "location=$location" \
  packer-nginx.json
```

When this completes, we will get an image `nginx-base-image` in the resource group specified. Similarly, we can
create the updated image (`nginx-updated-image`) by adding the following line to the provisioners script, updating
the `managed_image_name` to `nginx-updated-image` and build the image.

```sh
sed -i -e 's/Welcome to nginx/Welcome to nginx on Azure VMSS/' /var/www/html/index*.html
```

After that we can get the VMSS image ID for the base image and the updated one:

```sh
base_image_id="$(az image show --resource-group "$resource_group" --name nginx-base-image --query id --output tsv)"
export updated_image_id="$(az image show --resource-group "$resource_group" --name nginx-updated-image --query id --output tsv)"
```

Now that we have two images, we can do the canary deployment as follows:

1. Initially, we need to speicify the base image ID when we create the VMSS:

   ```sh
   # create the VMSS with 3 instances using the public Ubuntu LTS image
   az vmss create --resource-group "$resource_group" --name "$vmss_name" \
       --image "$base_image_id" \
       --admin-username "$admin_user" \
       --ssh-key-value "$ssh_pubkey" \
       --vm-sku Standard_D2_v3 \
       --instance-count 3 \
       --lb "${vmss_name}LB"
   ```

2. When we deploy new release, we update the image in VMSS configuration:

   ```sh
   az vmss update --resource-group "$resource_group" --name "$vmss_name" --set "virtualMachineProfile.storageProfile.imageReference.id=$updated_image_id"
   ```

3. Now we can selectively update certain instance to using the latest image with command `az vmss update-instances`, or upgrade
   all instances with `--instance-ids` setting to `*`.

   ```sh
   # pick up the first instance ID
   instance_id="$(az vmss list-instances --resource-group "$resource_group" --name "$vmss_name" --query '[].instanceId' --output tsv | head -n1)"
   # update the instance VM
   az vmss update-instances --resource-group "$resource_group" --name "$vmss_name" --instance-ids "$instance_id"
   ```

## Canary Deployment with Jenkins

In canary deployment we may roll out new releases to the servers gradually, which may involve multiple deployments
that updates the old releases / new releases server ratio. This may not be suitable to automate in limited number
of Jenkins jobs.

However, if we simplify the process, and we can model the process with parameterized Jenkins jobs. We have published [Azure Virtual Machine Scale Set](https://plugins.jenkins.io/azure-vmss) Jenkins plugin which helps to deploy new images to VMSS.

The above image based canary deployment can be modeled as two Jenkins Pipeline jobs:

* Deploy to a subset of instances

   ```groovy
   node {
       // ...

       stage('Update Image Configuration') {
          azureVMSSUpdate azureCredentialsId: '<azure-credential-id>', resourceGroup: env.resource_group, name: env.vmss_name,
                          imageReference: [id: env.updated_image_id]
       }

       stage('Update A Subset of Instances') {
          azureVMSSUpdateInstances azureCredentialsId: '<azure-credential-id>', resourceGroup: env.resource_group, name: env.vmss_name,
                                   instanceIds: '0,1'
       }

       // ...
   }
   ```

* Upgrade all the rest instances to the latest image

   ```groovy
   node {
      stage('Update All Instances') {
          azureVMSSUpdateInstances azureCredentialsId: '<azure-credential-id>', resourceGroup: env.resource_group, name: env.vmss_name,
                                   instanceIds: '*'
      }
   }
   ```

As mentioned in the previous example, you need to implement extra logic to test and validate if the new image is working properly.
