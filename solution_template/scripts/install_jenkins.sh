#!/bin/bash
echo $@
function print_usage() {
  cat <<EOF
Installs Jenkins and exposes it to the public through port 80 (login and cli are disabled)
Command
  $0
Arguments
  --jenkins_fqdn|-jf       [Required] : Jenkins FQDN
  --jenkins_release_type|-jrt         : The Jenkins release type (LTS or weekly or verified). By default it's set to LTS
  --jdk_type|-jt                      : The type of installed JDK.
  --jenkins_version_location|-jvl     : Url used to specify the version of Jenkins.
  --service_principal_type|-sp        : The type of service principal: managed-identities-for-azure-resources or manual.
  --service_principal_id|-sid         : The service principal ID.
  --service_principal_secret|-ss      : The service principal secret.
  --subscription_id|-subid            : The subscription ID of the SP.
  --tenant_id|-tid                    : The tenant id of the SP.
  --azure_env|-ae                     : The Azure environment. Default is 'Azure'.
  --artifacts_location|-al            : Url used to reference other scripts/artifacts.
  --sas_token|-st                     : A sas token needed if the artifacts location is private.
  --cloud_agents|-ca                  : The type of the cloud agents: aci, vm or no.
  --resource_group|-rg                : the resource group name.
  --location|-lo                      : the resource group location.
  --artifact_manager_enabled|-ame     : Whether default enable Azure artifact manager.
  --storage_account|-sa               : The storage account name for artifact manager.
  --storage_key|-sk                   : The storage key for artifact manager.
  --storage_endpoint|-se              : The storage blob endpoint for artifact manager.
  --artifact_container|-ac            : The container name for artifact manger.
  --artifact_prefix|-ap               : The prefix value for artifact manager.
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
  curl --silent "${artifacts_location}${script_path}${artifacts_location_sas_token}" | sudo bash -s -- "$@"
  local return_value=$?
  if [ $return_value -ne 0 ]; then
    >&2 echo "Failed while executing script '$script_path' with parameters '$@'."
    exit $return_value
  fi
}

function retry_until_successful {
  counter=0
  "${@}"
  while [ $? -ne 0 ]; do
    if [[ "$counter" -gt 20 ]]; then
        exit 1
    else
        let counter++
    fi
    sleep 5
    "${@}"
  done;
}

#defaults
artifacts_location="https://raw.githubusercontent.com/Azure/jenkins/master/solution_template"
jenkins_version_location="https://raw.githubusercontent.com/Azure/jenkins/master/jenkins-verified-ver"
jenkins_fallback_version="2.73.3"
azure_web_page_location="/usr/share/nginx/azure"
jenkins_release_type="LTS"
jdk_type="zulu"
azure_env="Azure"

while [[ $# > 0 ]]
do
  key="$1"
  shift
  case $key in
    --jenkins_fqdn|-jf)
      jenkins_fqdn="$1"
      shift
      ;;
    --jenkins_release_type|-jrt)
      jenkins_release_type="$1"
      shift
      ;;
    --jdk_type|-jt)
      jdk_type="$1"
      shift
      ;;
    --jenkins_version_location|-jvl)
      jenkins_version_location="$1"
      shift
      ;;
    --service_principal_type|-sp)
      service_principal_type="$1"
      shift
      ;;
    --service_principal_id|-spid)
      service_principal_id="$1"
      shift
      ;;
    --service_principal_secret|-ss)
      service_principal_secret="$1"
      shift
      ;;
    --subscription_id|-subid)
      subscription_id="$1"
      shift
      ;;
    --tenant_id|-tid)
      tenant_id="$1"
      shift
      ;;
    --azure_env|-ae)
      azure_env="$1"
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
    --cloud_agents|-ca)
      cloud_agents="$1"
      shift
      ;;
    --resource_group|-rg)
      resource_group="$1"
      shift
      ;;
    --location|-lo)
      location="$1"
      shift
      ;;
    --artifact_manager_enabled|-ame)
      artifact_manager_enabled="$1"
      shift
      ;;
    --storage_account|-sa)
      storage_account="$1"
      shift
      ;;
    --storage_key|-sk)
      storage_key="$1"
      shift
      ;;
    --storage_endpoint|-se)
      storage_endpoint="$1"
      shift
      ;;
    --artifact_container|-ac)
      artifact_container="$1"
      shift
      ;;
    --artifact_prefix|-ap)
      artifact_prefix="$1"
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

throw_if_empty --jenkins_fqdn $jenkins_fqdn
throw_if_empty --jenkins_release_type $jenkins_release_type
if [[ "$jenkins_release_type" != "LTS" ]] && [[ "$jenkins_release_type" != "weekly" ]] && [[ "$jenkins_release_type" != "verified" ]]; then
  echo "Parameter jenkins_release_type can only be 'LTS' or 'weekly' or 'verified'! Current value is '$jenkins_release_type'"
  exit 1
fi
throw_if_empty --jdk_type $jdk_type
if [[ "$jdk_type" != "zulu" ]] && [[ "$jdk_type" != "openjdk" ]]; then
  echo "Parameter jdk_type can only be 'zulu' or 'openjdk'! Current value is '$jdk_type'"
  exit 1
fi

jenkins_url="http://${jenkins_fqdn}/"

jenkins_auth_matrix_conf=$(cat <<EOF
<authorizationStrategy class="hudson.security.ProjectMatrixAuthorizationStrategy">
    <permission>com.cloudbees.plugins.credentials.CredentialsProvider.Create:authenticated</permission>
    <permission>com.cloudbees.plugins.credentials.CredentialsProvider.Delete:authenticated</permission>
    <permission>com.cloudbees.plugins.credentials.CredentialsProvider.ManageDomains:authenticated</permission>
    <permission>com.cloudbees.plugins.credentials.CredentialsProvider.Update:authenticated</permission>
    <permission>com.cloudbees.plugins.credentials.CredentialsProvider.View:authenticated</permission>
    <permission>hudson.model.Computer.Build:authenticated</permission>
    <permission>hudson.model.Computer.Configure:authenticated</permission>
    <permission>hudson.model.Computer.Connect:authenticated</permission>
    <permission>hudson.model.Computer.Create:authenticated</permission>
    <permission>hudson.model.Computer.Delete:authenticated</permission>
    <permission>hudson.model.Computer.Disconnect:authenticated</permission>
    <permission>hudson.model.Hudson.Administer:authenticated</permission>
    <permission>hudson.model.Hudson.ConfigureUpdateCenter:authenticated</permission>
    <permission>hudson.model.Hudson.Read:authenticated</permission>
    <permission>hudson.model.Hudson.RunScripts:authenticated</permission>
    <permission>hudson.model.Hudson.UploadPlugins:authenticated</permission>
    <permission>hudson.model.Item.Build:authenticated</permission>
    <permission>hudson.model.Item.Cancel:authenticated</permission>
    <permission>hudson.model.Item.Configure:authenticated</permission>
    <permission>hudson.model.Item.Create:authenticated</permission>
    <permission>hudson.model.Item.Delete:authenticated</permission>
    <permission>hudson.model.Item.Discover:authenticated</permission>
    <permission>hudson.model.Item.Move:authenticated</permission>
    <permission>hudson.model.Item.Read:authenticated</permission>
    <permission>hudson.model.Item.Workspace:authenticated</permission>
    <permission>hudson.model.Run.Delete:authenticated</permission>
    <permission>hudson.model.Run.Replay:authenticated</permission>
    <permission>hudson.model.Run.Update:authenticated</permission>
    <permission>hudson.model.View.Configure:authenticated</permission>
    <permission>hudson.model.View.Create:authenticated</permission>
    <permission>hudson.model.View.Delete:authenticated</permission>
    <permission>hudson.model.View.Read:authenticated</permission>
    <permission>hudson.scm.SCM.Tag:authenticated</permission>
    <permission>hudson.model.Hudson.Read:anonymous</permission>
    <permission>hudson.model.Item.Discover:anonymous</permission>
    <permission>hudson.model.Item.Read:anonymous</permission>
</authorizationStrategy>
EOF
)

jenkins_location_conf=$(cat <<EOF
<?xml version='1.0' encoding='UTF-8'?>
<jenkins.model.JenkinsLocationConfiguration>
    <adminAddress>address not configured yet &lt;nobody@nowhere&gt;</adminAddress>
    <jenkinsUrl>${jenkins_url}</jenkinsUrl>
</jenkins.model.JenkinsLocationConfiguration>
EOF
)

jenkins_disable_reverse_proxy_warning=$(cat <<EOF
<disabledAdministrativeMonitors>
    <string>hudson.diagnosis.ReverseProxySetupMonitor</string>
</disabledAdministrativeMonitors>
EOF
)

jenkins_agent_port="<slaveAgentPort>5378</slaveAgentPort>"

nginx_reverse_proxy_conf=$(cat <<EOF
server {
    listen 80;
    server_name ${jenkins_fqdn};
    error_page 403 /jenkins-on-azure;
    location / {
        proxy_set_header        Host \$host:\$server_port;
        proxy_set_header        X-Real-IP \$remote_addr;
        proxy_set_header        X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header        X-Forwarded-Proto \$scheme;


        # Fix the “It appears that your reverse proxy set up is broken" error.
        proxy_pass          http://localhost:8080;
        proxy_redirect      http://localhost:8080 http://${jenkins_fqdn};
        proxy_read_timeout  90;
    }
    location /cli {
        rewrite ^ /jenkins-on-azure permanent;
    }

    location ~ /login* {
        rewrite ^ /jenkins-on-azure permanent;
    }
    location /jenkins-on-azure {
      alias ${azure_web_page_location};
    }
}
EOF
)

#update apt repositories
wget -q -O - https://pkg.jenkins.io/debian/jenkins-ci.org.key | sudo apt-key add -

if [ "$jenkins_release_type" == "weekly" ]; then
  sudo sh -c 'echo deb http://pkg.jenkins.io/debian binary/ > /etc/apt/sources.list.d/jenkins.list'
else
  sudo sh -c 'echo deb http://pkg.jenkins.io/debian-stable binary/ > /etc/apt/sources.list.d/jenkins.list'
fi

if [ "$jdk_type" == "zulu" ]; then
  sudo apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 0xB1998361219BD9C9
  sudo add-apt-repository "deb http://repos.azul.com/azure-only/zulu/apt stable main" --yes
else
  sudo add-apt-repository ppa:openjdk-r/ppa --yes
fi

echo "deb [arch=amd64] https://packages.microsoft.com/repos/azure-cli/ $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/azure-cli.list
wget -q -O - https://packages.microsoft.com/keys/microsoft.asc | sudo apt-key add -
sudo apt-get install apt-transport-https
sudo apt-get update --yes

#install jdk8
if [ "$jdk_type" == "zulu" ]; then
  sudo apt-get install zulu-8-azure-jdk --yes
else
  sudo apt-get install openjdk-8-jdk --yes
fi

#install jenkins
if [[ ${jenkins_release_type} == 'verified' ]]; then
  jenkins_version=$(curl --silent "${jenkins_version_location}")
  if [ -z "$jenkins_version" ]; then
    jenkins_version=${jenkins_fallback_version}
  fi
  deb_file=jenkins_${jenkins_version}_all.deb
  wget -q "https://pkg.jenkins.io/debian-stable/binary/${deb_file}"
  if [[ -f ${deb_file} ]]; then
    sudo dpkg -i ${deb_file}
    sudo apt-get install -f --yes
  else
    echo "Failed to download ${deb_file}. The initialization is terminated!"
    exit -1
  fi
else
  sudo apt-get install jenkins --yes
  sudo apt-get install jenkins --yes # sometime the first apt-get install jenkins command fails, so we try it twice
fi

# wait until Jenkins is started and running
retry_until_successful sudo test -f /var/lib/jenkins/secrets/initialAdminPassword
retry_until_successful run_util_script "scripts/run-cli-command.sh" -c "version"

#We need to install workflow-aggregator so all the options in the auth matrix are valid
plugins=(azure-vm-agents windows-azure-storage matrix-auth workflow-aggregator azure-app-service tfs azure-acs azure-container-agents azure-function azure-ad azure-vmss service-fabric kubernetes-cd azure-container-registry-tasks azure-artifact-manager)
for plugin in "${plugins[@]}"; do
  run_util_script "scripts/run-cli-command.sh" -c "install-plugin $plugin -deploy"
done

#allow anonymous read access
inter_jenkins_config=$(sed -zr -e"s|<authorizationStrategy.*</authorizationStrategy>|{auth-strategy-token}|" /var/lib/jenkins/config.xml)
final_jenkins_config=${inter_jenkins_config//'{auth-strategy-token}'/${jenkins_auth_matrix_conf}}
echo "${final_jenkins_config}" | sudo tee /var/lib/jenkins/config.xml > /dev/null

#set up Jenkins URL to private_ip:8080 so JNLP connections can be established
echo "${jenkins_location_conf}" | sudo tee /var/lib/jenkins/jenkins.model.JenkinsLocationConfiguration.xml > /dev/null

#disable 'It appears that your reverse proxy set up is broken' warning.
# This is visible when connecting through SSH tunneling
inter_jenkins_config=$(sed -zr -e"s|<disabledAdministrativeMonitors/>|{disable-reverse-proxy-token}|" /var/lib/jenkins/config.xml)
final_jenkins_config=${inter_jenkins_config//'{disable-reverse-proxy-token}'/${jenkins_disable_reverse_proxy_warning}}
echo "${final_jenkins_config}" | sudo tee /var/lib/jenkins/config.xml > /dev/null

#Open a fixed port for JNLP
inter_jenkins_config=$(sed -zr -e"s|<slaveAgentPort.*</slaveAgentPort>|{slave-agent-port}|" /var/lib/jenkins/config.xml)
final_jenkins_config=${inter_jenkins_config//'{slave-agent-port}'/${jenkins_agent_port}}
echo "${final_jenkins_config}" | sudo tee /var/lib/jenkins/config.xml > /dev/null

#restart jenkins
sudo service jenkins restart

#install the service principal
imds_cred=$(cat <<EOF
<com.microsoft.azure.util.AzureImdsCredentials>
  <scope>GLOBAL</scope>
  <id>azure_service_principal</id>
  <description>Local Managed Identities for Azure Resources</description>
</com.microsoft.azure.util.AzureImdsCredentials>
EOF
)
sp_cred=$(cat <<EOF
<com.microsoft.azure.util.AzureCredentials>
  <scope>GLOBAL</scope>
  <id>azure_service_principal</id>
  <description>Manual Service Principal</description>
  <data>
    <subscriptionId>${subscription_id}</subscriptionId>
    <clientId>${service_principal_id}</clientId>
    <clientSecret>${service_principal_secret}</clientSecret>
    <tenant>${tenant_id}</tenant>
    <azureEnvironmentName>${azure_env}</azureEnvironmentName>
  </data>
</com.microsoft.azure.util.AzureCredentials>
EOF
)
if [ "${service_principal_type}" == 'managed-identities-for-azure-resources' ]; then
  echo "${imds_cred}" > imds_cred.xml
  run_util_script "scripts/run-cli-command.sh" -c "create-credentials-by-xml system::system::jenkins _" -cif imds_cred.xml
  rm imds_cred.xml
elif [ "${service_principal_type}" == 'manual' ]; then
  echo "${sp_cred}" > sp_cred.xml
  run_util_script "scripts/run-cli-command.sh" -c "create-credentials-by-xml system::system::jenkins _" -cif sp_cred.xml
  rm sp_cred.xml
elif [ "${service_principal_type}" == 'off' ]; then
  cloud_agents="no"
fi

#generate storage credential
storage_cred=$(cat <<EOF
<com.microsoftopentechnologies.windowsazurestorage.helper.AzureStorageAccount plugin="windows-azure-storage">
  <scope>GLOBAL</scope>
  <id>artifact_storage</id>
  <description>The storage credential for artifact manager</description>
  <storageData>
    <storageAccountName>${storage_account}</storageAccountName>
    <storageAccountKey>${storage_key}</storageAccountKey>
    <blobEndpointURL>${storage_endpoint}</blobEndpointURL>
  </storageData>
</com.microsoftopentechnologies.windowsazurestorage.helper.AzureStorageAccount>
EOF
)

#generate artifact manager configuration
azure_artifact=$(cat <<EOF
<?xml version='1.1' encoding='UTF-8'?>
<jenkins.model.ArtifactManagerConfiguration>
  <artifactManagerFactories>
    <com.microsoft.jenkins.artifactmanager.AzureArtifactManagerFactory plugin="azure-artifact-manager">
      <config>
        <storageCredentialId>artifact_storage</storageCredentialId>
        <container>${artifact_container}</container>
        <prefix>${artifact_prefix}</prefix>
      </config>
    </com.microsoft.jenkins.artifactmanager.AzureArtifactManagerFactory>
  </artifactManagerFactories>
</jenkins.model.ArtifactManagerConfiguration>
EOF
)

if [ "${artifact_manager_enabled}" == 'yes' ]; then
  echo "${storage_cred}" > storage_cred.xml
  run_util_script "scripts/run-cli-command.sh" -c "create-credentials-by-xml system::system::jenkins _" -cif storage_cred.xml
  rm storage_cred.xml

  echo "${azure_artifact}" | sudo tee /var/lib/jenkins/jenkins.model.ArtifactManagerConfiguration.xml > /dev/null
fi

#generate ssh key
ssh-keygen -t rsa -b 4096 -N '' -f /tmp/jenkins_ssh_key
ssh_public_key=$(cat /tmp/jenkins_ssh_key.pub)
ssh_private_key=$(cat /tmp/jenkins_ssh_key)
rm /tmp/jenkins_ssh_key{,.pub}

ssh_key_cred=$(cat <<EOF
<com.cloudbees.jenkins.plugins.sshcredentials.impl.BasicSSHUserPrivateKey>
          <scope>GLOBAL</scope>
          <id>slave_ssh_key</id>
          <description></description>
          <username>jenkins</username>
          <privateKeySource class="com.cloudbees.jenkins.plugins.sshcredentials.impl.BasicSSHUserPrivateKey\$DirectEntryPrivateKeySource">
            <privateKey>${ssh_private_key}</privateKey>
          </privateKeySource>
</com.cloudbees.jenkins.plugins.sshcredentials.impl.BasicSSHUserPrivateKey>
EOF
)
echo "${ssh_key_cred}" > ssh_key_cred.xml
run_util_script "scripts/run-cli-command.sh" -c "create-credentials-by-xml system::system::jenkins _" -cif ssh_key_cred.xml
rm ssh_key_cred.xml

#add cloud agents
vm_agent_conf=conf=$(cat <<EOF
<clouds>
  <com.microsoft.azure.vmagent.AzureVMCloud>
    <name>AzureVMAgents</name>
    <cloudName>AzureVMAgents</cloudName>
    <credentialsId>azure_service_principal</credentialsId>
    <maxVirtualMachinesLimit>10</maxVirtualMachinesLimit>
    <resourceGroupReferenceType>existing</resourceGroupReferenceType>
    <existingResourceGroupName>${resource_group}</existingResourceGroupName>
    <vmTemplates>
      <com.microsoft.azure.vmagent.AzureVMAgentTemplate>
        <templateName>win-agent</templateName>
        <labels>win</labels>
        <location>${location}</location>
        <virtualMachineSize>Standard_D1_v2</virtualMachineSize>
        <storageAccountNameReferenceType>new</storageAccountNameReferenceType>
        <diskType>managed</diskType>
        <storageAccountType>Standard_LRS</storageAccountType>
        <noOfParallelJobs>1</noOfParallelJobs>
        <usageMode>NORMAL</usageMode>
        <shutdownOnIdle>false</shutdownOnIdle>
        <imageTopLevelType>basic</imageTopLevelType>
        <builtInImage>Windows Server 2016</builtInImage>
        <credentialsId>agent_admin_account</credentialsId>
        <retentionTimeInMin>60</retentionTimeInMin>
      </com.microsoft.azure.vmagent.AzureVMAgentTemplate>
      <com.microsoft.azure.vmagent.AzureVMAgentTemplate>
        <templateName>linux-agent</templateName>
        <labels>linux</labels>
        <location>${location}</location>
        <virtualMachineSize>Standard_D1_v2</virtualMachineSize>
        <storageAccountNameReferenceType>new</storageAccountNameReferenceType>
        <diskType>managed</diskType>
        <storageAccountType>Standard_LRS</storageAccountType>
        <noOfParallelJobs>1</noOfParallelJobs>
        <usageMode>NORMAL</usageMode>
        <shutdownOnIdle>false</shutdownOnIdle>
        <imageTopLevelType>basic</imageTopLevelType>
        <builtInImage>Ubuntu 16.04 LTS</builtInImage>
        <credentialsId>agent_admin_account</credentialsId>
        <retentionTimeInMin>60</retentionTimeInMin>
      </com.microsoft.azure.vmagent.AzureVMAgentTemplate>
    </vmTemplates>
    <deploymentTimeout>1200</deploymentTimeout>
    <approximateVirtualMachineCount>0</approximateVirtualMachineCount>
  </com.microsoft.azure.vmagent.AzureVMCloud>
</clouds>
EOF
)

aci_agent_conf=$(cat <<EOF
<clouds>
  <com.microsoft.jenkins.containeragents.aci.AciCloud>
    <name>AciAgents</name>
    <credentialsId>azure_service_principal</credentialsId>
    <resourceGroup>${resource_group}</resourceGroup>
    <templates>
      <com.microsoft.jenkins.containeragents.aci.AciContainerTemplate>
        <name>aciagents</name>
        <label>linux</label>
        <image>jenkinsci/ssh-slave</image>
        <osType>Linux</osType>
        <command>setup-sshd</command>
        <rootFs>/home/jenkins</rootFs>
        <timeout>10</timeout>
        <ports/>
        <cpu>1</cpu>
        <memory>1.5</memory>
        <retentionStrategy class="com.microsoft.jenkins.containeragents.strategy.ContainerOnceRetentionStrategy">
          <idleMinutes>10</idleMinutes>
        </retentionStrategy>
        <envVars>
          <com.microsoft.jenkins.containeragents.PodEnvVar>
            <key>JENKINS_SLAVE_SSH_PUBKEY</key>
            <value>${ssh_public_key}</value>
          </com.microsoft.jenkins.containeragents.PodEnvVar>
        </envVars>
        <privateRegistryCredentials/>
        <volumes/>
        <launchMethodType>ssh</launchMethodType>
        <sshCredentialsId>slave_ssh_key</sshCredentialsId>
        <sshPort>22</sshPort>
        <isAvailable>true</isAvailable>
      </com.microsoft.jenkins.containeragents.aci.AciContainerTemplate>
    </templates>
  </com.microsoft.jenkins.containeragents.aci.AciCloud>
</clouds>
EOF
)

agent_admin_password=$(head /dev/urandom | tr -dc A-Z | head -c 4)$(head /dev/urandom | tr -dc a-z | head -c 4)$(head /dev/urandom | tr -dc 0-9 | head -c 4)'!@'
agent_admin_cred=$(cat <<EOF
<com.cloudbees.plugins.credentials.impl.UsernamePasswordCredentialsImpl>
  <scope>GLOBAL</scope>
  <id>agent_admin_account</id>
  <description>the admin account for the vm agents</description>
  <username>agentadmin</username>
  <password>${agent_admin_password}</password>
</com.cloudbees.plugins.credentials.impl.UsernamePasswordCredentialsImpl>
EOF
)

if [ "${cloud_agents}" == 'vm' ]; then
  echo "${agent_admin_cred}" > agent_admin_cred.xml
  run_util_script "scripts/run-cli-command.sh" -c "create-credentials-by-xml system::system::jenkins _" -cif agent_admin_cred.xml
  rm agent_admin_cred.xml
  inter_jenkins_config=$(sed -zr -e"s|<clouds/>|{clouds}|" /var/lib/jenkins/config.xml)
  final_jenkins_config=${inter_jenkins_config//'{clouds}'/${vm_agent_conf}}
  echo "${final_jenkins_config}" | sudo tee /var/lib/jenkins/config.xml > /dev/null
elif [ "${cloud_agents}" == 'aci' ]; then
  inter_jenkins_config=$(sed -zr -e"s|<clouds/>|{clouds}|" /var/lib/jenkins/config.xml)
  final_jenkins_config=${inter_jenkins_config//'{clouds}'/${aci_agent_conf}}
  echo "${final_jenkins_config}" | sudo tee /var/lib/jenkins/config.xml > /dev/null
fi

#install nginx
sudo apt-get install nginx --yes

#configure nginx
echo "${nginx_reverse_proxy_conf}" | sudo tee /etc/nginx/sites-enabled/default > /dev/null

#don't show version in headers
sudo sed -i "s|.*server_tokens.*|server_tokens off;|" /etc/nginx/nginx.conf

#install jenkins-on-azure web page
run_util_script "scripts/install-web-page.sh" -u "${jenkins_fqdn}"  -l "${azure_web_page_location}" -al "${artifacts_location}" -st "${artifacts_location_sas_token}"

#restart nginx
sudo service nginx restart

# Restart Jenkins
#
# As of Jenkins 2.107.3, reload-configuration is not sufficient to instruct Jenkins to pick up all the configuration
# updates gracefully. Jenkins will be trapped in the blank SetupWizard mode after initial user setup, and the user
# cannot proceed their work on the Jenkins instance.
#
# A restart will do the full reloading.
sudo service jenkins restart
# Wait until Jenkins is fully startup and functioning.
retry_until_successful run_util_script "scripts/run-cli-command.sh" -c "version"

#install common tools
sudo apt-get install git --yes
sudo apt-get install azure-cli --yes
