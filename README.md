# Power BI utils

The purpose of this repository is to provide developers with tools and utilities to implement solutions on Power BI.

## 🚀 Getting Started

This repository contains automated scripts for Power BI workflows. Choose the script that best fits your use case and follow the instructions provided in each section.

## Contents

### 📁 [doc](https://github.com/javendia/Fabric/blob/main/doc)

Full documentation about the Power BI projects.

### 📁 [tabular](https://github.com/javendia/Fabric/blob/main/tabular)

Scripts to automate actions over a tabular model.

- 🔗 **[tabular/BimToPBIP.csx](https://github.com/javendia/Fabric/blob/main/tabular/BimToPBIP.csx)**
    - **Description**
        Script to convert an on-premises Microsoft SQL Server Analysis Services tabular model to a Power BI project (.pbip).
    - **Prerequisites**
        - [Tabular Editor 2.x](https://github.com/TabularEditor/TabularEditor/releases).
        - An empty Power BI project (.pbip).
    - **How it works**
        - The first step is to extract the metadata from the tabular model. We can get it using Tabular Editor as follows:
            1. Connect with the desired tabular model.
            
               <p align="center">
                 <img src="./tabular/media/tabular-01.png" alt="Connect to tabular model.">
               </p>
            2. Save metadata.
            
               <p align="center">
                 <img src="./tabular/media/tabular-02.png" alt="Save metadata step 1">
               </p>
               <p align="center">
                 <img src="./tabular/media/tabular-03.png" alt="Save metadata step 2">
               </p>
            
        - Secondly, we will open the extracted tabular model and finally run the script on Tabular Editor. The script prompts you for two values:
            - The server name for the destination SQL database.
            - The database name for the destination SQL database.
    - **Limitations**
        - The compatibility level must be higher or equal than 1400 (SQL Server Analysis Services 2017 or later).
        - It is planned to work with SQL data sources only.

### 📁 [pbi](https://github.com/javendia/Fabric/blob/main/pbi)

Scripts to perform actions over Power BI reports.

- 🔗 **[pbi/MigratePBI.ps1](https://github.com/javendia/Fabric/blob/main/pbi/MigratePBI.ps1)**
    - **Description**
        
        Script to convert a Power BI report (.pbix) to a Power BI project (.pbip) and publish it to the service.
    - **Prerequisites**
        
        - [PowerShell 7.x](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-windows?view=powershell-7.5).
        - Permission to execute PowerShell scripts.

        ```powershell
        Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
        ```
    - **How it works**
        
        - Firstly, the script requests some data to the user:
            - The path to Power BI files to convert.
            - Destination workspace name.
            - In order to bind the report, the corresponding semantic model id.
        - During the execution, the script creates a subfolder in the directory passed as argument. After that, you must save the report as Power BI project manually. The project must be placed in the subfolder created previously.
        - Finally, the report is published to Power BI service and it is linked to the semantic model.

- 🔗 **[pbi/CleanupConnections.ps1](https://github.com/javendia/Fabric/blob/main/pbi/CleanupConnections.ps1)**
    - **Description**
        
        Script to detect broken or unused Power BI / Microsoft Fabric connections and delete them optionally.
    - **Prerequisites**
        
        - [PowerShell 7.x](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-windows).
        - Modules `Az.Accounts` and `ImportExcel` (installed automatically for the current user if missing).
        - No Power BI / Microsoft Fabric admin role is required: the script works with the permissions of the signed-in user.
        - Owner role on the connections, or admin role on their gateway, to check and delete them, and access to the workspaces where they may be used.
    - **How it works**
        
        - Signs in to Power BI with your Microsoft account.
        - Lists the connections with the Microsoft Fabric REST API. Connections you neither own nor manage as gateway admin are not checked and are reported as `No permission`.
        - For the connections you own, checks their status with the Power BI API (`Get Datasource Status`) and their usage by scanning the items of every workspace you have access to (`List Item Connections`).
        - Builds a table with the connection name, type and status (`Broken`, `Unused` or `No permission`) and asks whether to show it in the terminal or export it to Excel (saved in the current directory).
        - Finally, asks whether to delete any of the broken or unused connections.
    - **Limitations**
        
        - The connections of an item can only be read with write permission on it. The script warns about the items it could not check.
        - The status of virtual network gateway connections cannot be checked, so they are only evaluated by usage.
        - Virtual network gateway admins who are not owners of a connection see it as `No permission`, even though they could delete it.

## 📄 License

This project is licensed under the MIT License - see the LICENSE file for details.
