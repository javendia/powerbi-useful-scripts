#r "Microsoft.VisualBasic"
using Microsoft.VisualBasic;
using System.IO;
using System.Text.RegularExpressions;

/*

    Author: Javier Buendia
    Created: 2025-03-01
    Updated: 2026-10-13
    Description: The following script adapts an SSAS Tabular (.bim) model 
                to be included in an empty Power BI project (.pbip) or Power BI Desktop.
                It preserves all existing M expressions (both navigation and Value.NativeQuery),
                replaces SSAS structured data source pointers with Sql.Database(...),
                removes legacy SSAS DataSources and annotations, and cleans up roles.

*/

// 1. Collect existing data source names to replace their references in M partitions
var dataSourceNames = new List<string>();
foreach (var ds in Model.DataSources)
{
    dataSourceNames.Add(ds.Name);
}

// 2. Prompt user for target server and database
string __ServerName = Interaction.InputBox(
    Prompt: "Enter name for the server:",
    Title: "Server",
    DefaultResponse: ""
);
if (string.IsNullOrWhiteSpace(__ServerName))
{
    Error("No server name provided. Migration canceled.");
    return;
}

string __DatabaseName = Interaction.InputBox(
    Prompt: "Enter name for the database:",
    Title: "Database",
    DefaultResponse: ""
);
if (string.IsNullOrWhiteSpace(__DatabaseName))
{
    Error("No database name provided. Migration canceled.");
    return;
}

// 3. Compatibility Level & Power BI V3 Configuration
var __CompatibilityLevel = 1550;
var __DefaultPowerBIDataSourceVersion = PowerBIDataSourceVersion.PowerBI_V3;

Model.Database.CompatibilityLevel = __CompatibilityLevel;
Model.DefaultPowerBIDataSourceVersion = __DefaultPowerBIDataSourceVersion;
Model.SetAnnotation("__PBI_TimeIntelligenceEnabled", "0");

// 4. Transform M Partitions without destroying existing logic (Navigation, Value.NativeQuery, etc.)
string sqlDbExpr = string.Format("Sql.Database(\"{0}\", \"{1}\")", 
    __ServerName.Replace("\"", "\"\""), 
    __DatabaseName.Replace("\"", "\"\""));

int convertedPartitionsCount = 0;

foreach (var t in Model.Tables)
{
    // Only target M partitions, leave calculated tables (DAX) untouched
    foreach (var p in t.Partitions.Where(part => part.SourceType == PartitionSourceType.M).ToList())
    {
        // Skip partitions with empty expressions
        if (string.IsNullOrEmpty(p.Expression))
            continue;

        string mExpr = p.Expression;

        // Replace references to known data sources
        foreach (var dsName in dataSourceNames)
        {
            // Case 1: Escaped identifier #"DataSourceName"
            string escapedRef = "#\"" + dsName + "\"";
            if (mExpr.Contains(escapedRef))
            {
                mExpr = mExpr.Replace(escapedRef, sqlDbExpr);
            }

            // Case 2: Unescaped identifier (word boundary)
            mExpr = Regex.Replace(mExpr, @"\b" + Regex.Escape(dsName) + @"\b", sqlDbExpr);
        }

        // Fallback: replace any remaining legacy SSAS data source identifier pattern #"SQL/..." or #"TDS/..."
        mExpr = Regex.Replace(mExpr, @"#""(SQL|TDS|OLEDB)/[^""]+""", sqlDbExpr, RegexOptions.IgnoreCase);

        // Remove legacy SSDT serialization annotation that causes issues in Power BI Desktop
        p.RemoveAnnotation("QueryEditorSerialization");

        p.Expression = mExpr;
        p.Mode = ModeType.Import;
        convertedPartitionsCount++;
    }
}

// 5. Clean up roles for Power BI Desktop compatibility
foreach (var r in Model.Roles.ToList())
{
    // Windows domain user / SID member definitions are not supported in Power BI Desktop (managed in Power BI Service)
    while (r.Members.Count > 0)
    {
        r.Members[0].Delete();
    }

    // Administrator role permission is not supported in Power BI Desktop models
    if (r.ModelPermission == ModelPermission.Administrator)
    {
        r.ModelPermission = ModelPermission.Read;
    }
}

// 6. Delete existing data sources (Power BI V3 models do not use Model.DataSources)
while (Model.DataSources.Count > 0)
{
    Model.DataSources[0].Delete();
}

// 7. Summary
Info(string.Format("Migration to Power BI completed successfully!\n\n- Converted M Partitions: {0}\n- Data Sources removed: {1}\n- Compatibility Level: {2}\n- Target: {3} / {4}", 
    convertedPartitionsCount, 
    dataSourceNames.Count, 
    __CompatibilityLevel, 
    __ServerName, 
    __DatabaseName));
