#!/bin/bash

function print_usage() {
  cat <<EOF
Command
  $0
Arguments
  --jenkins_url|-j                [Required]: Jenkins URL
  --jenkins_username|-ju          [Required]: Jenkins user name
  --jenkins_password|-jp                    : Jenkins password. If not specified and the user name is "admin", the initialAdminPassword will be used
  --aks_resource_group|-ag        [Required]: Resource group for the target Azure Kubernetes Service (AKS)
  --aks_name|-an                  [Required]: Name of the AKS
  --sp_credentials_id|-spi                  : Desired Jenkins Azure service principal ID
  --sp_credentials_desc|-spd                : Desired Jenkins Azure service princiapl description
  --sp_subscription_id|-sps       [Required]: Subscription ID for the Azure service principal
  --sp_client_id|-spc             [Required]: Client ID for the Azure service principal
  --sp_client_password|-spp       [Required]: Client secrets for the Azure service principal
  --sp_tenant_id|-spt             [Required]: Tenant ID for the Azure service principal
  --sp_environment|-spe                     : Azure environment for the Azure service principal
  --bg_job_short_name                       : Jenkins job short name for K8s blue/green deployment
  --bg_job_display_name                     : Desired Jenkins job display name for K8s blue/green deployment
  --bg_job_description                      : Desired Jenkins job description for K8s blue/green deployment
  --rolling_job_short_name                  : Desired Jenkins job short name for K8s rolling update
  --rolling_job_display_name                : Desired Jenkins job display name for K8s rolling update
  --rolling_job_description                 : Desired Jenkins job description for K8s rolling update
  --artifacts_location|-al                  : Url used to reference other scripts/artifacts.
  --sas_token|-st                           : A sas token needed if the artifacts location is private.
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

#set defaults
sp_credentials_id="sp"
sp_credentials_desc="Service Principal to manage Azure resources"
sp_environment="Azure"
bg_job_short_name="aks-blue-green-deployment"
bg_job_display_name="AKS Kubernetes Blue/green Deployment"
bg_job_description="A pipeline that demonstrates the blue/green deployment to AKS Kubernetes with the azure-acs Jenkins plugin."
rolling_job_short_name="aks-rolling-update-deployment"
rolling_job_display_name="AKS Kubernetes Rolling Update Deployment"
rolling_job_description="A pipeline that demonstrates the rolling update deployment to AKS Kubernetes with the azure-acs Jenkins plugin."
artifacts_location="https://raw.githubusercontent.com/Azure/jenkins/master"

while [[ $# > 0 ]]
do
  key="$1"
  shift
  case $key in
    --jenkins_url|-j)
      jenkins_url="$1"
      shift
      ;;
    --jenkins_username|-ju)
      jenkins_username="$1"
      shift
      ;;
    --jenkins_password|-jp)
      jenkins_password="$1"
      shift
      ;;
    --aks_resource_group|-ag)
      aks_resource_group="$1"
      shift
      ;;
    --aks_name|-an)
      aks_name="$1"
      shift
      ;;
    --sp_credentials_id|-spi)
      sp_credentials_id="$1"
      shift
      ;;
    --sp_credentials_desc|-spd)
      sp_credentials_desc="$1"
      shift
      ;;
    --sp_subscription_id|-sps)
      sp_subscription_id="$1"
      shift
      ;;
    --sp_client_id|-spc)
      sp_client_id="$1"
      shift
      ;;
    --sp_client_password|-spp)
      sp_client_password="$1"
      shift
      ;;
    --sp_tenant_id|-spt)
      sp_tenant_id="$1"
      shift
      ;;
    --sp_environment|-spe)
      sp_environment="$1"
      shift
      ;;
    --bg_job_short_name)
      bg_job_short_name="$1"
      shift
      ;;
    --bg_job_display_name)
      bg_job_display_name="$1"
      shift
      ;;
    --bg_job_description)
      bg_job_description="$1"
      shift
      ;;
    --rolling_job_short_name)
      rolling_job_short_name="$1"
      shift
      ;;
    --rolling_job_display_name)
      rolling_job_display_name="$1"
      shift
      ;;
    --rolling_job_description)
      rolling_job_description="$1"
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

throw_if_empty --jenkins_url "$jenkins_url"
throw_if_empty --jenkins_username "$jenkins_username"
if [ "$jenkins_username" != "admin" ]; then
  throw_if_empty --jenkins_password "$jenkins_password"
fi
throw_if_empty --aks_resource_group "$aks_resource_group"
throw_if_empty --aks_name "$aks_name"
throw_if_empty --sp_credentials_id "$sp_credentials_id"
throw_if_empty --sp_subscription_id "$sp_subscription_id"
throw_if_empty --sp_client_id "$sp_client_id"
throw_if_empty --sp_client_password "$sp_client_password"
throw_if_empty --sp_tenant_id "$sp_tenant_id"
throw_if_empty --sp_environment "$sp_environment"

#download dependencies
bg_job_xml=$(curl -s ${artifacts_location}/quickstart_templates/zero_downtime_deployment/kubernetes/aks-blue-green-job.xml${artifacts_location_sas_token})
rolling_job_xml=$(curl -s ${artifacts_location}/quickstart_templates/zero_downtime_deployment/kubernetes/aks-rolling-update-job.xml${artifacts_location_sas_token})
sp_credentials_xml=$(curl -s ${artifacts_location}/quickstart_templates/shared/sp-credentials.xml${artifacts_location_sas_token})

# prepare blue/green deployment job XML
bg_job_xml=${bg_job_xml//'{insert-job-display-name}'/${bg_job_display_name}}
bg_job_xml=${bg_job_xml//'{insert-job-description}'/${bg_job_description}}
bg_job_xml=${bg_job_xml//'{insert-aks-resource-group}'/${aks_resource_group}}
bg_job_xml=${bg_job_xml//'{insert-aks-name}'/${aks_name}}
bg_job_xml=${bg_job_xml//'{insert-artifacts-location}'/${artifacts_location}}
bg_job_xml=${bg_job_xml//'{insert-sas-token}'/${artifacts_location_sas_token}}

# prepare rolling job XML
rolling_job_xml=${rolling_job_xml//'{insert-job-display-name}'/${rolling_job_display_name}}
rolling_job_xml=${rolling_job_xml//'{insert-job-description}'/${rolling_job_description}}
rolling_job_xml=${rolling_job_xml//'{insert-aks-resource-group}'/${aks_resource_group}}
rolling_job_xml=${rolling_job_xml//'{insert-aks-name}'/${aks_name}}
rolling_job_xml=${rolling_job_xml//'{insert-artifacts-location}'/${artifacts_location}}
rolling_job_xml=${rolling_job_xml//'{insert-sas-token}'/${artifacts_location_sas_token}}

# prepare sp-credentials.xml
sp_credentials_xml=${sp_credentials_xml//'{insert-sp-credentials-id}'/${sp_credentials_id}}
sp_credentials_xml=${sp_credentials_xml//'{insert-sp-credentials-desc}'/${sp_credentials_desc}}
sp_credentials_xml=${sp_credentials_xml//'{insert-sp-subscription-id}'/${sp_subscription_id}}
sp_credentials_xml=${sp_credentials_xml//'{insert-sp-client-id}'/${sp_client_id}}
sp_credentials_xml=${sp_credentials_xml//'{insert-sp-client-password}'/${sp_client_password}}
sp_credentials_xml=${sp_credentials_xml//'{insert-sp-tenant-id}'/${sp_tenant_id}}
sp_credentials_xml=${sp_credentials_xml//'{insert-sp-environment}'/${sp_environment}}

#add Azure service principal credentials
echo "${sp_credentials_xml}" >sp-credentials.xml
run_util_script "solution_template/scripts/run-cli-command.sh" -j "$jenkins_url" -ju "$jenkins_username" -jp "$jenkins_password" -c 'create-credentials-by-xml SystemCredentialsProvider::SystemContextResolver::jenkins (global)' -cif "sp-credentials.xml"

#add job
echo "${bg_job_xml}" >bg-job.xml
run_util_script "solution_template/scripts/run-cli-command.sh" -j "$jenkins_url" -ju "$jenkins_username" -jp "$jenkins_password" -c "create-job ${bg_job_short_name}" -cif "bg-job.xml"

echo "${rolling_job_xml}" >rolling-job.xml
run_util_script "solution_template/scripts/run-cli-command.sh" -j "$jenkins_url" -ju "$jenkins_username" -jp "$jenkins_password" -c "create-job ${rolling_job_short_name}" -cif "rolling-job.xml"

# clean up
rm -f sp-credentials.xml job.xml
