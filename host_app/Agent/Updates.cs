using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Security.Cryptography;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Windows;
using Microsoft.Win32;

namespace EpicVM.Desktop;

sealed partial class AgentWindow
{
    static readonly string installRoot=Path.GetFullPath(Path.Combine(AppContext.BaseDirectory,".."));
    readonly System.Windows.Controls.TextBlock releaseDetails=Label("Reading installed versions…");
    readonly System.Windows.Controls.TextBlock updateDetails=Label("Select a release ZIP downloaded from a source you trust. Packages are checked for integrity; they are not digitally signed.");
    bool updaterLaunching;
    bool packageInspecting;
    void BuildUpdates() {
        var about=Page(navigation,"About & updates","Installed versions and controlled host updates.");
        var installed=Section("Installed on this PC","Versions help identify exactly which host build is running.");
        installed.Children.Add(releaseDetails);about.Children.Add(Card(installed));
        var updates=Section("Install a release","Every update is checked before files change. Private host state, accounts and profiles stay on this PC.");
        updates.Children.Add(updateDetails);
        updates.Children.Add(Row(Action("Choose update package…",()=>_ = ChooseUpdate()),Action("Roll back last update…",()=>_ = RollBackUpdate())));
        updates.Children.Add(Label("Agent updates reopen this app. Core updates restart host control. Streaming updates require you to end active desktops first. A failed verification restores the previous files."));
        about.Children.Add(Card(updates));
        about.Children.Add(Action("Host setup and component checks",()=>new SetupWindow().Show()));
        about.Children.Add(Action("Open setup guide",()=>{try{Process.Start(new ProcessStartInfo(Path.Combine(installRoot,"scripts","WINDOWS-HOST-UPDATES.md")){UseShellExecute=true});}catch(Exception ex){ShowNotice(ex.Message);}}));
    }
    void UpdateVersions() {
        releaseDetails.Text=$"Agent: {typeof(AgentWindow).Assembly.GetName().Version}\nHost release: {snapshot?["release"]?.ToString() ?? "Legacy install"}\nControl service: {snapshot?["controlVersion"]?.ToString() ?? "Not reported by this Control build"}\nWindows: {Environment.OSVersion.VersionString}\nArchitecture: {System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture}";
        if(snapshot?["lastUpdate"] is JsonObject last) updateDetails.Text=$"Last update: {last["status"]} · {last["finishedAt"]}\n{last["message"]}\nUse release ZIPs from a source you trust. Packages have integrity checks, not a publisher signature.";
    }
    static (string Version,string Impact,string Hash) InspectPackage(string path) {
        using var archive=ZipFile.OpenRead(path);
        if(archive.Entries.Count>3000 || archive.Entries.Sum(e=>e.Length)>1024L*1024*1024)throw new InvalidOperationException("Package exceeds the supported size.");
        if(archive.Entries.GroupBy(e=>e.FullName,StringComparer.OrdinalIgnoreCase).Any(g=>g.Count()>1))throw new InvalidOperationException("Package contains duplicate destinations.");
        var manifestEntry=archive.GetEntry("release.json") ?? throw new InvalidOperationException("Missing release manifest.");
        if(manifestEntry.Length>1024*1024)throw new InvalidOperationException("Release manifest is too large.");
        using var reader=new StreamReader(manifestEntry.Open());var manifest=JsonNode.Parse(reader.ReadToEnd())!.AsObject();
        if(manifest["schema"]?.GetValue<int>()!=1 || manifest["product"]?.ToString()!="EpicVM Host" || !Regex.IsMatch(manifest["version"]?.ToString() ?? "",@"^\d+\.\d+\.\d+([.-][a-zA-Z0-9.-]+)?$"))throw new InvalidOperationException("Unsupported EpicVM release.");
        var files=manifest["files"]!.AsArray();if(files.Count==0)throw new InvalidOperationException("Empty release.");
        if(files.Count!=archive.Entries.Count(e=>!e.FullName.EndsWith('/'))-1)throw new InvalidOperationException("Package has unlisted files.");
        var paths=files.Select(f=>f!["path"]!.ToString()).ToArray();
        if(paths.Distinct(StringComparer.OrdinalIgnoreCase).Count()!=paths.Length)throw new InvalidOperationException("Duplicate release file.");
        foreach(var file in files){
            string destination=file!["path"]!.ToString();
            bool supported=Regex.IsMatch(destination,@"^(ui|control)/[a-zA-Z0-9_./-]+$") || Regex.IsMatch(destination,@"^scripts/(HostUpdates\.ps1|Update-EpicVMHost\.ps1|Setup-EpicVMHost\.ps1|Install-EpicVMHostRuntime\.ps1|agent_update_wait\.py|WINDOWS-HOST-UPDATES\.md|host_runtime\.py|manage_host_runtime\.py|supervise_host_direct_streams\.py|provision_direct_stream\.py|host_stream_gateway\.py|direct_stream_auth\.py|write_direct_stream_caddy\.py|Start-EpicVMLocalGateway\.ps1|stream_recovery\.js|stream_network\.js)$");
            if(!supported || destination.Split('/').Any(p=>p is "." or ".." or ""))throw new InvalidOperationException("Unsupported update destination.");
            var entry=archive.GetEntry(destination) ?? throw new InvalidOperationException("Release file is missing.");
            using var stream=entry.Open();if(!Convert.ToHexString(SHA256.HashData(stream)).Equals(file["sha256"]?.ToString(),StringComparison.OrdinalIgnoreCase))throw new InvalidOperationException("Package integrity check failed.");
        }
        bool runtime=paths.Any(p=>Regex.IsMatch(p,@"^scripts/(host_runtime|manage_host_runtime|supervise_host_direct_streams|provision_direct_stream|host_stream_gateway|direct_stream_auth|write_direct_stream_caddy|Start-EpicVMLocalGateway|stream_recovery|stream_network)\."));
        using var source=File.OpenRead(path);var packageHash=Convert.ToHexString(SHA256.HashData(source));
        return (manifest["version"]!.ToString(),runtime ? "desktops-must-end" : paths.Any(p=>p.StartsWith("control/")) ? "control-restart" : "agent-only",packageHash);
    }
    async Task ChooseUpdate() {
        if(operationPending || updaterLaunching || packageInspecting)return;
        var dialog=new OpenFileDialog{Filter="EpicVM release package|*.zip"};if(dialog.ShowDialog()!=true)return;
        packageInspecting=true;
        try {
            updateDetails.Text="Checking package files…";
            var package=await Task.Run(()=>InspectPackage(dialog.FileName));
            string impact=package.Impact=="desktops-must-end" ? "This package includes streaming code. End all active desktops before continuing." : package.Impact=="control-restart" ? "Host control will restart. Windows desktops stay running." : "The Agent will close and reopen. Hosting stays running.";
            if(!Confirm($"Install EpicVM Host {package.Version}?\n\n{impact}\n\nOnly install packages from a source you trust.")) { UpdateVersions();return; }
            await LaunchUpdater("-PackagePath",dialog.FileName,package.Hash);
        }catch(Exception ex){ShowNotice(ex.Message);UpdateVersions();}finally{packageInspecting=false;}
    }
    async Task RollBackUpdate() {
        if(operationPending || updaterLaunching || packageInspecting)return;
        var last=snapshot?["rollbackUpdate"] ?? snapshot?["lastUpdate"];
        if(last?["rollbackAvailable"]?.GetValue<bool>()!=true || last["id"]?.ToString() is not string id){ShowNotice("No completed update is available for rollback.");return;}
        if(!Confirm("Restore the files from before the last update? The Agent will reopen. If streaming files changed, end active desktops first. Windows accounts and profiles are preserved."))return;
        try{await LaunchUpdater("-RollbackId",id);}catch(Exception ex){ShowNotice(ex.Message);}
    }
    async Task LaunchUpdater(string option,string value,string? packageHash=null) {
        if(!CanQuit())return;
        string updater=Path.Combine(installRoot,"scripts","Update-EpicVMHost.ps1"),python=Path.Combine(installRoot,"python","python.exe"),watcher=Path.Combine(installRoot,"scripts","agent_update_wait.py");
        if(!File.Exists(updater) || !File.Exists(python) || !File.Exists(watcher)){ShowNotice("Update support is not installed. Use the release's Update-EpicVMHost.ps1 as administrator to install this first update.");return;}
        updaterLaunching=true;SetPending(true);
        string result=Path.Combine(Path.GetTempPath(),"epicvm-update-"+Guid.NewGuid().ToString("N")+".json");
        try {
            var info=new ProcessStartInfo("powershell.exe"){UseShellExecute=true,Verb="runas"};
            foreach(var argument in new[]{"-NoProfile","-ExecutionPolicy","Bypass","-File",updater,option,value,"-AgentPid",Environment.ProcessId.ToString(),"-ResultPath",result})info.ArgumentList.Add(argument);
            if(packageHash!=null){info.ArgumentList.Add("-ExpectedPackageSha256");info.ArgumentList.Add(packageHash);}
            using var elevated=Process.Start(info) ?? throw new InvalidOperationException("Could not start the updater.");
            var wait=new ProcessStartInfo(python){UseShellExecute=false,CreateNoWindow=true};
            foreach(var argument in new[]{watcher,result,Path.Combine(installRoot,"ui","EpicVM.Agent.exe"),elevated.Id.ToString(),Environment.ProcessId.ToString()})wait.ArgumentList.Add(argument);
            using var relaunch=Process.Start(wait) ?? throw new InvalidOperationException("Could not prepare the Agent restart. No update can proceed while the Agent stays open.");
            timer.Stop();tray.Dispose();Application.Current.Shutdown();
        }catch(Exception ex){updaterLaunching=false;SetPending(false);ShowNotice(ex.Message);}
        await Task.CompletedTask;
    }
}
