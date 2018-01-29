#!/bin/bash

function print_usage() {
  cat <<EOF
https://github.com/Azure/jenkins/blob/master/quickstart_templates/zero_downtime_deployment/301-jenkins-vmss-zero-downtime-deployment.sh
Command
  $0
Arguments
  --app_id|-ai                       [Required] : Service principal app id  used to dynamically manage resource in your subscription
  --app_key|-ak                      [Required] : Service principal app key used to dynamically manage resource in your subscription
  --subscription_id|-si              [Required] : Subscription Id
  --tenant_id|-ti                    [Required] : Tenant Id
  --resource_group|-rg               [Required] : Resource group containing your Kubernetes cluster
  --location|-lo                     [Required] : Location of the resource group
  --name_prefix|-np                  [Required] : Resource name prefix without trailing hyphen.
  --jenkins_fqdn|-jf                 [Required] : Jenkins FQDN
  --service_name|-sn                            : The service name. Should be the same as the routing rule name in the VMSS frontend load balancer.
  --image_name|-in                              : If specified, the script build a managed OS image with Tomcat 7 installed,
                                                  which will be stored in the passed in resource group using this name.
  --artifacts_location|-al                      : Url used to reference other scripts/artifacts.
  --sas_token|-st                               : A sas token needed if the artifacts location is private.
EOF
}

function throw_if_empty() {
  local name="$1"
  local value="$2"
  if [ -z "$value" ]; then
    echo "Parameter '$name' cannot be empty." 1>&2
    print_usage
    exit -1
  fi
}

function run_util_script() {
  local script_path="$1"
  shift
  curl --silent "${artifacts_location}/${script_path}${artifacts_location_sas_token}" | sudo bash -s -- "$@"
  local return_value=$?
  if [ $return_value -ne 0 ]; then
    >&2 echo "Failed while executing script '$script_path'."
    exit $return_value
  fi
}

function install_az() {
  if !(command -v az >/dev/null); then
    sudo apt-get update && sudo apt-get install -y libssl-dev libffi-dev python-dev
    echo "deb [arch=amd64] https://apt-mo.trafficmanager.net/repos/azure-cli/ wheezy main" | sudo tee /etc/apt/sources.list.d/azure-cli.list
    sudo apt-key adv --keyserver apt-mo.trafficmanager.net --recv-keys 417A0893
    sudo apt-get install -y apt-transport-https
    sudo apt-get -y update && sudo apt-get install -y azure-cli
  fi
}

service_name=tomcat
artifacts_location="https://raw.githubusercontent.com/Azure/jenkins/master"

while [[ $# > 0 ]]
do
  key="$1"
  shift
  case "$key" in
    --app_id|-ai)
      app_id="$1"
      shift
      ;;
    --app_key|-ak)
      app_key="$1"
      shift
      ;;
    --subscription_id|-si)
      subscription_id="$1"
      shift
      ;;
    --tenant_id|-ti)
      tenant_id="$1"
      shift
      ;;
    --resource_group|-rg)
      resource_group="$1"
      shift
      ;;
    --location|-lo)
      location="$1"
      shift;
      ;;
    --name_prefix|-np)
      name_prefix="$1"
      shift
      ;;
    --jenkins_fqdn|-jf)
      jenkins_fqdn="$1"
      shift
      ;;
    --service_name|-sn)
      service_name="$1"
      shift
      ;;
    --image_name|-in)
      image_name="$1"
      shift
      ;;
    --artifacts_location|-al)
      artifacts_location="$1"
      shift
      ;;
    --sas_token|-st)
      artifacts_location_sas_token="$1"
      shift
      ;;
    --help|-help|-h)
      print_usage
      exit 13
      ;;
    *)
      echo "ERROR: Unknown argument '$key' to script '$0'" 1>&2
      exit -1
  esac
done

throw_if_empty --app_id "$app_id"
throw_if_empty --app_key "$app_key"
throw_if_empty --subscription_id "$subscription_id"
throw_if_empty --tenant_id "$tenant_id"
throw_if_empty --resource_group "$resource_group"
throw_if_empty --location "$location"
throw_if_empty --name_prefix "$name_prefix"
throw_if_empty --jenkins_fqdn "$jenkins_fqdn"

sudo apt-get install --yes jq curl

install_az

az login --service-principal -u "$app_id" -p "$app_key" --tenant "$tenant_id"
az account set --subscription "$subscription_id"
location="$(az group show --name "$resource_group" --query location --output tsv)"
if [[ -z "$location" ]]; then
  echo "Cannot determine location of resource group '$resource_group' in script '$0'" >&2
  exit -1
fi

if [[ -n "$image_name" ]]; then
  run_util_script "quickstart_templates/zero_downtime_deployment/vmss/packer-build-tomcat-image.sh" \
    --app_id "$app_id" \
    --app_key "$app_key" \
    --subscription_id "$subscription_id" \
    --tenant_id "$tenant_id" \
    --tomcat_version 7 \
    --image_name "$image_name" \
    --resource_group "$resource_group" \
    --location "$location" \
    --artifacts_location "$artifacts_location" \
    --sas_token "$sas_token"
  
  image_id="$(az image show --resource-group "${resource_group}" --name "${image_name}" --query id --output tsv)"
  if [[ -z "$image_id" ]]; then
    echo "Failed to build the image '${image_name} in resource group '${resource_group}'" >&2
    exit 1
  fi
fi

az logout

#install jenkins
run_util_script "solution_template/scripts/install_jenkins.sh" \
  --jenkins_release_type verified \
  --jenkins_version_location "${artifacts_location}/quickstart_templates/shared/verified-jenkins-version${artifacts_location_sas_token}" \
  --jenkins_fqdn "${jenkins_fqdn}" \
  --artifacts_location "${artifacts_location}/solution_template" \
  --sas_token "${artifacts_location_sas_token}"

run_util_script "solution_template/scripts/run-cli-command.sh" -c "install-plugin ssh-agent -deploy"
run_util_script "solution_template/scripts/run-cli-command.sh" -c "install-plugin azure-vmss -deploy"

run_util_script "quickstart_templates/zero_downtime_deployment/vmss/add-jenkins-jobs.sh" \
    -j "http://localhost:8080/" \
    -ju "admin" \
    --resource_group "$resource_group" \
    --name_prefix "$name_prefix" \
    --service_name "$service_name" \
    --sp_subscription_id "$subscription_id" \
    --sp_client_id "$app_id" \
    --sp_client_password "$app_key" \
    --sp_tenant_id "$tenant_id" \
    --artifacts_location "$artifacts_location" \
    --sas_token "$artifacts_location_sas_token"
