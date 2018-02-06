#!/bin/bash

function print_usage() {
  cat <<EOF
Command
  $0
Arguments
  --app_id|-ai                       [Required] : Service principal app id  used to dynamically manage resource in your subscription
  --app_key|-ak                      [Required] : Service principal app key used to dynamically manage resource in your subscription
  --subscription_id|-si              [Required] : Subscription Id
  --tenant_id|-ti                    [Required] : Tenant Id
  --tomcat_version|-tv                          : Tomcat version to install in the image
  --image_name|-in                              : Result OS image name
  --resource_group|-rg               [Required] : Resource group to store the resulting image
  --location|-lo                     [Required] : Location of the resulting image
  --vm_size|-vs                                 : SKU of the source VM which the OS image will be built from
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

function install_packer() {
  if !(command -v packer >/dev/null); then
    sudo apt-get install --yes unzip
    wget https://releases.hashicorp.com/packer/1.1.3/packer_1.1.3_linux_amd64.zip -O packer.zip
    sudo unzip -d /usr/local/bin packer.zip
    sudo chmod +x /usr/local/bin/packer
  fi
}

tomcat_version=7
vm_size=Standard_DS2_v2
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
    --tomcat_version|-tv)
      tomcat_version="$1"
      shift
      ;;
    --image_name|-in)
      image_name="$1"
      shift;
      ;;
    --resource_group|-rg)
      resource_group="$1"
      shift
      ;;
    --location|-lo)
      location="$1"
      shift
      ;;
    --vm_size|-vs)
      vm_size="$1"
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
throw_if_empty --tomcat_version "$tomcat_version"
throw_if_empty --resource_group "$resource_group"
throw_if_empty --location "$location"

if [[ "$tomcat_version" != 7 ]] && [[ "$tomcat_version" != 8 ]]; then
  echo "ERROR: Only 7 or 8 is allowed for tomcat version to script '$0'" 1>&2
  exit -1
fi

if [[ -z "$image_name" ]]; then
  image_name="tomcat-$tomcat_version"
fi

install_packer

wget "${artifacts_location}/quickstart_templates/zero_downtime_deployment/vmss/packer-tomcat.json${artifacts_location_sas_token}" -O packer-tomcat.json

packer build \
  -var "client_id=$app_id" \
  -var "client_secret=$app_key" \
  -var "subscription_id=$subscription_id" \
  -var "tenant_id=$tenant_id" \
  -var "tomcat_version=$tomcat_version" \
  -var "image_name=$image_name" \
  -var "resource_group=$resource_group" \
  -var "location=$location" \
  -var "vm_size=$vm_size" \
  packer-tomcat.json

rm -f packer-tomcat.json
