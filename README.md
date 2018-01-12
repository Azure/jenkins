# Jenkins on Azure
This repository contains Jenkins related resources in Azure.

## Contents
* Jenkins Solution Template (/solution_template) 
  * This [solution template](https://azuremarketplace.microsoft.com/en-us/marketplace/apps/azure-oss.jenkins?tab=Overview) will deploy the latest stable Jenkins version on a Linux (Ubuntu 16.04 LTS) VM along with tools and plugins configured to work with Azure
* Jenkins Agents Initialization Scripts (/agents_scripts)
  * These scripts setup a new provisioned Windows VM as a Jenkins agent.
  * [Jenkins-Windows-Init-Script-Jnlp.ps1](agents_scripts/Jenkins-Windows-Init-Script-Jnlp.ps1) launches the agent via JNLP.
  * [Jenkins-Windows-Init-Script-SSH.ps1](agents_scripts/Jenkins-Windows-Init-Script-SSH.ps1) launches the agent via SSH.

## Questions/Comments?

_This project has adopted the [Microsoft Open Source Code of Conduct](https://opensource.microsoft.com/codeofconduct/). For more information see the [Code of Conduct FAQ](https://opensource.microsoft.com/codeofconduct/faq/) or contact [opencode@microsoft.com](mailto:opencode@microsoft.com) with any additional questions or comments._

## Legal Notices
Microsoft and any contributors grant you a license to the Microsoft documentation and other content in this repository under the [Creative Commons Attribution 4.0 International Public License](https://creativecommons.org/licenses/by/4.0/legalcode), see the [LICENSE](LICENSE) file, and grant you a license to any code in the repository under the MIT License, see the [LICENSE-CODE](LICENSE-CODE) file.