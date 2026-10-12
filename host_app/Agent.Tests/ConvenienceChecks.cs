using System;
using System.Diagnostics;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using System.Windows;

namespace EpicVM.Desktop;

sealed partial class AgentWindow
{
    internal async Task<int> CheckConvenience() {
        int count=0,prompts=0;bool discard=false;
        void Check(bool value,string label) { if(!value) throw new Exception(label);count++; }
        confirmDiscard=_=>{prompts++;return discard;};
        var state=JsonNode.Parse("""
            {"runtime":{"updatedAt":9999999999,"state":"ready"},"services":{"Runtime":"Running"},
             "hostId":"test","publicOrigin":"https://normal.example.com","lan":{"enabled":true,"origin":"https://lan.example.com:8443"},
             "policy":{"paused":false,"maxSeats":0,"width":1920,"height":1080,"fps":60,"normalEnabled":true,"localEnabled":true},
             "startAtBoot":true,"seats":[],"resources":[],"games":[{"id":"first","title":"First game","executable":"C:\\Games\\First.exe"},{"id":"second","title":"Second game","executable":"C:\\Games\\Second.exe"}]}
            """)!.AsObject();
        readStatus=_=>Task.FromResult(state.DeepClone().AsObject());readTrayStartup=()=>false;
        await Refresh(true);
        Check(ConnectionLink("normal")=="https://normal.example.com/" && ConnectionLink("local")=="https://lan.example.com:8443/","Both connection addresses normalize safely");
        Check(values["local"].Text=="https://lan.example.com:8443/","Local card shows actual address");
        Check(connectionButtons["normal"][0].IsEnabled && connectionButtons["local"][1].IsEnabled,"Configured connections enable copy/open");
        string? copied=null,opened=null;copyLink=value=>copied=value;openLink=value=>opened=value;
        UseConnection("normal",false);Check(copied=="https://normal.example.com/","Copy uses current normal address");
        UseConnection("local",true);Check(opened=="https://lan.example.com:8443/EpicVM/auth/health","Open uses reachable gateway check instead of unauthenticated stream");
        foreach(var invalid in new[]{"file:///C:/Windows","javascript:alert(1)","https://user:password@example.com/","https://example.com/?token=secret","https://example.com/#secret"}) Check(SafeLink(invalid)==null,"Unsafe or credential-bearing link rejected");
        state["policy"]!["localEnabled"]=false;await Refresh();
        Check(ConnectionLink("local")==null && !connectionButtons["local"][0].IsEnabled,"Disabled LAN cannot be copied/opened");
        opened=null;UseConnection("local",true);Check(opened==null,"Disabled connection cannot launch even through handler");
        Check(trayStatus.Text=="Host ready" && trayPause.Text=="Pause new desktops","Ready tray status");
        state["policy"]!["paused"]=true;await Refresh();
        Check(trayStatus.Text=="Hosting paused" && trayPause.Text=="Resume new desktops","Paused tray status and Resume");
        JsonObject? submitted=null;
        applyRequest=request=>{submitted=request.DeepClone().AsObject();state["policy"]=request["policy"]!.DeepClone();return Task.CompletedTask;};
        ToggleTrayPause();
        Check(submitted?["policy"]?["paused"]?.GetValue<bool>()==false && submitted["policy"]!["fps"]!.GetValue<int>()==60,"Tray Resume preserves other policy settings");
        state["services"]!["Runtime"]="Stopped";await Refresh();Check(trayStatus.Text=="Hosting stopped","Stopped tray status");
        UpdateConvenience(false);Check(trayStatus.Text=="Host unavailable" && !trayPause.Enabled && !connectionButtons["normal"][0].IsEnabled,"Unavailable host disables stale actions");
        games.SelectedIndex=0;gameTitle.Text="Draft title";
        games.SelectedIndex=1;
        Check(games.SelectedItem is Game old && old.Id=="first" && gameTitle.Text=="Draft title" && prompts==1,"Cancelled game switch restores selection and draft");
        NewGame();Check(gameTitle.Text=="Draft title" && GameDirty,"Cancelled New game preserves draft");
        Check(!CanQuit(),"Dirty game blocks cancelled Quit");
        discard=true;games.SelectedIndex=1;
        Check(gameTitle.Text=="Second game" && !GameDirty,"Confirmed switch loads selected game");
        gameTitle.Text="Unsaved second";NewGame();Check(gameId.Text=="" && gameTitle.Text=="" && games.SelectedItem==null && !GameDirty,"Confirmed New game clears draft");
        fps.Text="120";discard=false;Check(!CanQuit(),"Hosting draft blocks cancelled Quit");
        discard=true;Check(CanQuit(),"Confirmed Quit permits discarding hosting edits");
        SetPending(true);Check(!CanQuit() && !trayPause.Enabled,"Quit and tray policy changes blocked during operation");SetPending(false);
        var scope="check-"+Guid.NewGuid().ToString("N");
        using(var first=new AgentInstance(scope)) {
            Check(first.IsFirst,"First process owns Agent instance");
            var activated=new TaskCompletionSource<bool>();first.Listen(()=>activated.TrySetResult(true));
            var info=new ProcessStartInfo(Environment.ProcessPath!){UseShellExecute=false,CreateNoWindow=true};
            info.ArgumentList.Add("--instance-probe");info.ArgumentList.Add(scope);
            using var child=Process.Start(info)!;await child.WaitForExitAsync();
            Check(child.ExitCode==0,"Second process recognizes existing instance");
            Check(await Task.WhenAny(activated.Task,Task.Delay(3000))==activated.Task,"Second process activation reaches original process");
        }
        using(var replacement=new AgentInstance(scope)) Check(replacement.IsFirst,"Instance can relaunch after original exits");
        return count;
    }
}
