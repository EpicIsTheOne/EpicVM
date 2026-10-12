using System;
using System.ComponentModel;
using System.IO;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using System.Windows;

namespace EpicVM.Desktop;

sealed partial class AgentWindow
{
    internal async Task<int> CheckRecovery() {
        int count=0,submissions=0;
        void Check(bool value,string message) { if(!value)throw new Exception(message);count++; }
        var state=JsonNode.Parse("""
            {"runtime":{"updatedAt":9999999999,"state":"ready"},"services":{"Runtime":"Running"},
             "hostId":"test","policy":{"paused":false,"maxSeats":0,"width":1920,"height":1080,"fps":60,"normalEnabled":true,"localEnabled":true},
             "startAtBoot":true,"seats":[{"id":"seat-1","accountName":"Example","status":"Ready"}],"resources":[],"games":[]}
            """)!.AsObject();
        readStatus=_=>Task.FromResult(state.DeepClone().AsObject());readTrayStartup=()=>false;
        await Refresh(true);seats.SelectedIndex=0;fps.Text="120";
        Check(lastSuccessfulUpdate!=null && freshness.Text.Contains("Live host data"),"Successful read shows timestamp");
        applyRequest=_=>{submissions++;return Task.CompletedTask;};
        foreach(var pair in new[]{
            (Error:(Exception)new UnauthorizedAccessException(),Title:"Access to host control was denied"),
            (Error:(Exception)new Win32Exception(5),Title:"Access to host control was denied"),
            (Error:(Exception)new HostControlOfflineException(new TimeoutException()),Title:"Host control is offline or busy"),
            (Error:(Exception)new TimeoutException(),Title:"Host control took too long to respond"),
            (Error:(Exception)new OperationCanceledException(),Title:"Host control took too long to respond"),
            (Error:(Exception)new IOException(),Title:"The host control connection was interrupted"),
            (Error:(Exception)new InvalidOperationException(),Title:"Host status could not be read")}) {
            readStatus=_=>Task.FromException<JsonObject>(pair.Error);await Refresh();
            Check(headline.Text==pair.Title && detail.Text.Length>20,"Specific control failure and next step");
        }
        Check(!statusAvailable && !seats.IsEnabled && seats.Items.Count==1 && sessionFreshness.Text.Contains("last known"),"Old rows retained and labelled unknown after read failure");
        Check(fps.Text=="120" && settingsDirty && saveSettings?.IsEnabled==false,"Offline refresh preserves draft and disables Save");
        Check(!await ApplyAsync(new(){["operation"]="seat-end",["seatId"]="seat-1"}) && submissions==0,"Stale data cannot authorize UI mutation");
        readStatus=_=>Task.FromResult(state.DeepClone().AsObject());await Refresh();
        Check(statusAvailable && seats.IsEnabled && saveSettings?.IsEnabled==true && !sessionFreshness.Text.Contains("last known"),"Recovery restores live rows/actions without losing draft");
        state["runtime"]!["updatedAt"]=0;await Refresh();
        Check(statusAvailable && freshness.Text.Contains("Runtime health is stale") && seats.IsEnabled,"Stale runtime health distinguished from fresh control rows");
        gameFileExists=path=>path==@"C:\Games\Example.exe";
        gameId.Text="BAD ID";gameTitle.Text="";gameExe.Text=@"C:\Games\missing.exe";SaveGame();
        Check(submissions==0 && fieldErrors[gameId].Visibility==Visibility.Visible && fieldErrors[gameTitle].Visibility==Visibility.Visible && fieldErrors[gameExe].Visibility==Visibility.Visible,"Invalid game rejected before submission with field errors");
        gameId.Text="example";gameTitle.Text="Example game";
        foreach(var path in new[]{@"C:\Windows\game.exe",@"C:\Users\Epic\game.exe",@"C:\Games\AppData\game.exe",@"\\server\share\game.exe",@"game.exe",@"C:\Games\Example.txt",@"C:\Games\missing.exe"}) {
            gameExe.Text=path;Check(!ValidateGame(false),"Unsupported or missing executable rejected");
        }
        gameExe.Text=@"C:\Games\nested\..\Example.exe";
        Check(ValidateGame(false),"Existing machine-installed executable accepted with normalized path");
        gameTitle.Text=new string('x',121);Check(!ValidateGame(false),"Overlong game title rejected");
        gameTitle.Text="Example game";SaveGame();
        Check(submissions==1 && fieldErrors[gameId].Visibility==Visibility.Collapsed && fieldErrors[gameTitle].Visibility==Visibility.Collapsed && fieldErrors[gameExe].Visibility==Visibility.Collapsed,"Valid game submits and clears errors");
        return count;
    }
}
