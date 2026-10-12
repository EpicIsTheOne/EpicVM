using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;

namespace EpicVM.Desktop;

sealed partial class AgentWindow
{
    internal async Task<int> CheckInteractions() {
        int count=0, submitted=0, trayWrites=0;
        void Check(bool condition,string description) { if(!condition) throw new Exception(description); count++; }
        var state=JsonNode.Parse("""
            {"runtime":{"updatedAt":9999999999,"state":"ready"},"services":{"Runtime":"Running"},
             "hostId":"test","policy":{"paused":false,"maxSeats":0,"width":1920,"height":1080,"fps":60,"normalEnabled":true,"localEnabled":true},
             "startAtBoot":true,"seats":[{"id":"seat-1","accountName":"LocalPlayer","status":"Ready"}],
             "resources":[{"route":"stream-1","enabled":true}],"games":[{"id":"game-1","title":"Example game","executable":"C:\\Games\\Example.exe"}]}
            """)!.AsObject();
        bool trayEnabled=false;
        readStatus=_=>Task.FromResult(state.DeepClone().AsObject());
        readTrayStartup=()=>trayEnabled;
        writeTrayStartup=enabled=>{trayWrites++;trayEnabled=enabled;};
        applyRequest=_=>{submitted++;return Task.CompletedTask;};
        Check(await Refresh(true),"Initial settings read");
        Check(!settingsDirty && saveSettings?.IsEnabled==false,"Clean settings disable Save");
        seats.SelectedIndex=0; resources.SelectedIndex=0; games.SelectedIndex=0;
        Check(gameId.Text=="game-1" && gameTitle.Text=="Example game" && gameExe.Text==@"C:\Games\Example.exe","Game selection fills editor");
        gameTitle.Text="Unsaved game title";
        state["seats"]![0]!["status"]="Connecting";
        state["resources"]![0]!["enabled"]=false;
        state["games"]![0]!["title"]="Updated elsewhere";
        await Refresh();
        Check(seats.SelectedItem is Seat s && s.Id=="seat-1" && s.Status=="Connecting","Desktop selection survives status refresh");
        Check(resources.SelectedItem is Resource r && r.Route=="stream-1" && !r.Enabled,"Stream selection survives refresh");
        Check(games.SelectedItem is Game g && g.Id=="game-1" && gameTitle.Text=="Unsaved game title","Game refresh preserves editor draft");
        state["seats"]=new JsonArray(); await Refresh();
        Check(seats.SelectedItem==null,"Removed desktop cannot stay selected");
        fps.Text="45";
        Check(settingsDirty && settingsState.Text=="Unsaved changes","Changed settings marked unsaved");
        await SaveAsync();
        Check(submitted==0 && fieldErrors[fps].Visibility==Visibility.Visible,"Unsupported FPS rejected before elevation");
        limits.Text="999999999999"; width.Text="123"; height.Text="777";
        Check(!ValidateSettings(false) && fieldErrors[limits].Visibility==Visibility.Visible && fieldErrors[width].Visibility==Visibility.Visible && fieldErrors[height].Visibility==Visibility.Visible,"Field validation covers overflow and unsupported dimensions");
        limits.Text="4"; width.Text="1920"; height.Text="1080"; fps.Text="120";
        await Refresh();
        Check(limits.Text=="4" && fps.Text=="120" && settingsDirty,"Periodic refresh preserves unsaved hosting settings");
        trayStartup.IsChecked=true;
        applyRequest=_=>Task.FromException(new Win32Exception(1223));
        await SaveAsync();
        Check(notice.Text.Contains("cancelled") && trayWrites==0 && settingsDirty,"Cancelled approval preserves edits and tray startup");
        applyRequest=_=>Task.FromException(new InvalidOperationException("Test host failure"));
        await SaveAsync();
        Check(notice.Text=="Test host failure" && trayWrites==0 && settingsDirty,"Host failure does not apply tray startup or discard edits");
        var pending=new TaskCompletionSource();
        applyRequest=req=>{submitted++;return pending.Task;};
        var saving=SaveAsync();
        Check(operationPending && !fps.IsEnabled && saveSettings?.IsEnabled==false,"Pending action locks editable fields");
        Check(!await ApplyAsync(new(){["operation"]="runtime-start"}) && submitted==1,"Duplicate action is blocked");
        state["policy"]!["maxSeats"]=4; state["policy"]!["fps"]=120;
        pending.SetResult(); await saving;
        Check(trayWrites==1 && trayEnabled && !settingsDirty && fps.Text=="120" && notice.Text=="Hosting settings saved.","Successful settings save reloads confirmed fields and writes tray startup");
        Check(!operationPending && fps.IsEnabled && saveSettings?.IsEnabled==false,"Controls restored after save");
        state["policy"]!["fps"]=60; await Refresh();
        Check(fps.Text=="60" && !settingsDirty,"Clean settings follow external changes");
        applyRequest=_=>Task.CompletedTask;
        readStatus=_=>Task.FromException<JsonObject>(new IOException("offline"));
        await ApplyAsync(new(){["operation"]="policy"});
        Check(notice.Text.Contains("could not be refreshed"),"Readback failure is distinguished from mutation failure");
        foreach(var code in new[]{0,3}) {
            var info=new ProcessStartInfo(Environment.ProcessPath!){UseShellExecute=false,CreateNoWindow=true};
            info.ArgumentList.Add("--child-result");info.ArgumentList.Add(code.ToString());
            using var child=Process.Start(info)!;
            bool failed=false;try{await Rpc.WaitForResult(child);}catch(InvalidOperationException){failed=true;}
            Check(failed==(code!=0),"Child process exit result propagated");
        }
        return count;
    }
}

static class InteractionTestRunner
{
    [STAThread] static void Main(string[] args) {
        if(args.Length==4&&args[0]=="--setup-operation"){Environment.ExitCode=SetupWindow.Operation(args[1],args[2],args[3]);return;}
        if(args.Length==2 && args[0]=="--child-result") { Environment.ExitCode=int.Parse(args[1]);return; }
        if(args.Length==2 && args[0]=="--instance-probe") { using var instance=new AgentInstance(args[1]);if(instance.IsFirst){Environment.ExitCode=1;return;}instance.ActivateExisting();return; }
        var app=new Application();
        app.Startup+=async(_,_)=>{
            try { var agent=new AgentWindow(false,true);var count=await agent.CheckInteractions();var convenience=new AgentWindow(false,true);var more=await convenience.CheckConvenience();var recovery=new AgentWindow(false,true);var failures=await recovery.CheckRecovery();var releases=agent.CheckReleases();var setup=new SetupWindow();var setupCount=await setup.CheckSetup();File.WriteAllText(args[0],$"{count} interaction, {more} convenience, {failures} recovery, {releases} release and {setupCount} setup checks passed.");app.Shutdown(0); }
            catch(Exception ex) { File.WriteAllText(args[0],ex.ToString());app.Shutdown(1); }
        };
        app.Run();
    }
}
