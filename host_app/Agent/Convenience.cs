using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Security.Principal;
using System.Text.Json.Nodes;
using System.Threading;
using System.Windows;
using System.Windows.Controls;

namespace EpicVM.Desktop;

sealed class AgentInstance : IDisposable
{
    readonly Mutex mutex;
    readonly EventWaitHandle activation;
    RegisteredWaitHandle? listener;
    public bool IsFirst { get; }
    internal AgentInstance(string? scope=null) {
        scope ??= WindowsIdentity.GetCurrent().User!.Value+"."+Process.GetCurrentProcess().SessionId;
        activation=new EventWaitHandle(false,EventResetMode.AutoReset,@"Local\EpicVM.Agent.Activate."+scope);
        mutex=new Mutex(false,@"Local\EpicVM.Agent.Instance."+scope,out bool created);
        IsFirst=created;
    }
    public void ActivateExisting() => activation.Set();
    public void Listen(Action open) => listener=ThreadPool.RegisterWaitForSingleObject(activation,(_,_)=>open(),null,Timeout.Infinite,false);
    public void Dispose() { listener?.Unregister(null); activation.Dispose(); mutex.Dispose(); }
}

sealed partial class AgentWindow
{
    Func<string,bool> confirmDiscard = message => Confirm(message);
    string gameBaseline="";
    Game? editorGame;
    bool selectingGame;
    readonly Dictionary<string,Button[]> connectionButtons=new();
    readonly System.Windows.Forms.ToolStripMenuItem trayStatus=new("Checking host…") { Enabled=false };
    readonly System.Windows.Forms.ToolStripMenuItem trayPause=new("Pause new desktops");
    Action<string> copyLink=Clipboard.SetText;
    Action<string> openLink=url=>Process.Start(new ProcessStartInfo(url){UseShellExecute=true});
    string GameDraft() => string.Join("\n",gameId.Text,gameTitle.Text,gameExe.Text);
    bool GameDirty => GameDraft()!=gameBaseline;
    bool DiscardGame() => !GameDirty || confirmDiscard("Discard your unsaved game edits?");
    void ChooseGame() {
        if(updatingGameRows || selectingGame || games.SelectedItem is not Game selected) return;
        if(editorGame?.Id==selected.Id) return;
        if(!DiscardGame()) {
            selectingGame=true; games.SelectedItem=games.Items.Cast<Game>().FirstOrDefault(g=>g.Id==editorGame?.Id); selectingGame=false; return;
        }
        editorGame=selected;
        gameId.Text=selected.Id;gameTitle.Text=selected.Title;gameExe.Text=selected.Executable;gameBaseline=GameDraft();
    }
    void NewGame() {
        if(!DiscardGame()) return;
        selectingGame=true;games.SelectedItem=null;selectingGame=false;
        editorGame=null; gameId.Clear();gameTitle.Clear();gameExe.Clear();gameBaseline=GameDraft();gameId.Focus();
    }
    void QuitAgent() {
        if(!CanQuit()) return;
        timer.Stop();tray.Dispose();Application.Current.Shutdown();
    }
    bool CanQuit() {
        if(operationPending) { ShowNotice("Wait for the host change to finish before quitting the Agent.");return false; }
        return !(settingsDirty || GameDirty) || confirmDiscard("Quit Agent and discard your unsaved hosting or game edits? Hosting will keep running.");
    }
    static string? SafeLink(string? value) {
        if(!Uri.TryCreate(value,UriKind.Absolute,out var uri) || (uri.Scheme!="https" && uri.Scheme!="http") || !string.IsNullOrEmpty(uri.UserInfo) || !string.IsNullOrEmpty(uri.Query) || !string.IsNullOrEmpty(uri.Fragment)) return null;
        return uri.AbsoluteUri;
    }
    string? ConnectionLink(string key) {
        if(snapshot==null) return null;
        if(key=="normal") return snapshot["policy"]?["normalEnabled"]?.GetValue<bool>()==false ? null : SafeLink(snapshot["publicOrigin"]?.ToString());
        return snapshot["policy"]?["localEnabled"]?.GetValue<bool>()==false || snapshot["lan"]?["enabled"]?.GetValue<bool>()!=true ? null : SafeLink(snapshot["lan"]?["origin"]?.ToString());
    }
    void LinkActions(Panel panel,string key) {
        var copy=Action("Copy address",()=>UseConnection(key,false)); var open=Action("Open connection check",()=>UseConnection(key,true));
        connectionButtons[key]=new[]{copy,open};panel.Children.Add(Row(copy,open));
    }
    void UseConnection(string key,bool open) {
        var url=ConnectionLink(key);if(url==null) { ShowNotice("This connection is unavailable or disabled.");return; }
        try {
            if(open) openLink(new Uri(new Uri(url),"/EpicVM/auth/health").AbsoluteUri);else copyLink(url);
            ShowNotice(open ? "Connection check opened in your browser. An ‘ok’ response means the gateway is reachable." : "Connection address copied.");
        }catch(Exception ex) { ShowNotice("Could not "+(open?"open":"copy")+" the connection: "+ex.Message); }
    }
    void UpdateConvenience(bool available=true) {
        foreach(var pair in connectionButtons) foreach(var button in pair.Value) button.IsEnabled=available && !operationPending && ConnectionLink(pair.Key)!=null;
        bool paused=snapshot?["policy"]?["paused"]?.GetValue<bool>()==true;
        string status=!available ? "Host unavailable" : snapshot?["services"]?["Runtime"]?.ToString()!="Running" ? "Hosting stopped" : headline.Text=="Host runtime is ready" ? paused ? "Hosting paused" : "Host ready" : "Host needs attention";
        tray.Text="EpicVM · "+status;trayStatus.Text=status;
        trayPause.Text=paused ? "Resume new desktops" : "Pause new desktops";
        trayPause.Enabled=available && snapshot?["policy"] is JsonObject && !operationPending;
        tray.Icon=status=="Host ready" ? System.Drawing.SystemIcons.Information : status=="Hosting paused" ? System.Drawing.SystemIcons.Application : System.Drawing.SystemIcons.Warning;
    }
    void ToggleTrayPause() {
        if(snapshot?["policy"] is not JsonObject policy || operationPending) return;
        var updated=policy.DeepClone().AsObject();updated["paused"]=policy["paused"]?.GetValue<bool>()!=true;
        Apply(new(){["operation"]="policy",["policy"]=updated});
    }
}
