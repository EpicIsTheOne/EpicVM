using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using Microsoft.Win32;

namespace EpicVM.Desktop;

sealed partial class AgentWindow
{
    Func<JsonObject,Task> applyRequest = Rpc.Apply;
    Func<JsonObject,Task<JsonObject>> readStatus = Rpc.Call;
    Func<bool> readTrayStartup = () => { using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run"); return key?.GetValue("EpicVM Agent") != null; };
    Action<bool> writeTrayStartup = enabled => {
        using var key = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");
        if(enabled) key.SetValue("EpicVM Agent",'"'+Environment.ProcessPath+"\" --tray"); else key.DeleteValue("EpicVM Agent",false);
    };
    readonly TextBlock settingsState = Label("Loading hosting settings…");
    readonly Dictionary<TextBox,TextBlock> fieldErrors = new();
    readonly List<Button> actionButtons = new();
    Button? saveSettings;
    bool operationPending, loadingSettings, settingsDirty, updatingGameRows;
    string? settingsBaseline;
    string Draft() => string.Join("|",new[]{boot.IsChecked.ToString(),trayStartup.IsChecked.ToString(),pause.IsChecked.ToString(),normal.IsChecked.ToString(),local.IsChecked.ToString(),limits.Text.Trim(),width.Text.Trim(),height.Text.Trim(),fps.Text.Trim()});
    void InitializeInteractions() {
        foreach(var box in new[]{boot,trayStartup,pause,normal,local}) { box.Checked += (_,_)=>SettingsEdited(); box.Unchecked += (_,_)=>SettingsEdited(); }
        foreach(var input in new[]{limits,width,height,fps}) input.TextChanged += (_,_)=>SettingsEdited();
        gameBaseline=GameDraft();
        games.SelectionChanged += (_,_)=>ChooseGame();
    }
    void SettingsEdited() {
        if(loadingSettings) return;
        settingsDirty = settingsBaseline != Draft();
        ValidateSettings(false);
        UpdateSettingsState();
        UpdateConvenience(statusAvailable);
    }
    void UpdateSettingsState() {
        settingsState.Text = operationPending ? "Applying change…" : settingsBaseline == null ? "Waiting for host settings." : settingsDirty ? "Unsaved changes" : "Settings are up to date.";
        settingsState.Foreground = Ink(settingsDirty ? "#FFCC8A" : "#A6AEC5");
        if(saveSettings != null) saveSettings.IsEnabled = statusAvailable && !operationPending && settingsBaseline != null && settingsDirty;
    }
    StackPanel InputWithError(TextBox field) {
        var stack = new StackPanel(); stack.Children.Add(field);
        var error = Label(""); error.Foreground = Ink("#FFB2BF"); error.Visibility = Visibility.Collapsed;
        error.Margin = new Thickness(0,0,0,10); fieldErrors[field] = error; stack.Children.Add(error); return stack;
    }
    bool ValidateSettings(bool focus) {
        var valid = true; TextBox? first = null;
        void Check(TextBox box, Func<int,bool> allowed, string message) {
            bool ok = int.TryParse(box.Text,out var value) && allowed(value);
            var error = fieldErrors[box]; error.Text = ok ? "" : message; error.Visibility = ok ? Visibility.Collapsed : Visibility.Visible;
            box.BorderBrush = Ink(ok ? "#30364B" : "#FFB2BF");
            if(!ok) { valid=false; first ??= box; }
        }
        Check(limits,v=>v>=0 && v<=64,"Enter a whole number from 0 to 64. Use 0 for unlimited.");
        Check(width,v=>new[]{1280,1600,1920,2560,3840}.Contains(v),"Choose a width: 1280, 1600, 1920, 2560 or 3840.");
        Check(height,v=>new[]{720,900,1080,1440,2160}.Contains(v),"Choose a height: 720, 900, 1080, 1440 or 2160.");
        Check(fps,v=>new[]{30,60,120}.Contains(v),"Choose 30, 60 or 120 FPS.");
        if(focus && first != null) { navigation.SelectedIndex=2; first.Focus(); first.BringIntoView(); }
        return valid;
    }
    void LoadSettings() {
        loadingSettings=true;
        try {
            boot.IsChecked=snapshot?["startAtBoot"]?.GetValue<bool>() ?? false;
            pause.IsChecked=snapshot?["policy"]?["paused"]?.GetValue<bool>() ?? false;
            normal.IsChecked=snapshot?["policy"]?["normalEnabled"]?.GetValue<bool>() ?? true;
            local.IsChecked=snapshot?["policy"]?["localEnabled"]?.GetValue<bool>() ?? true;
            limits.Text=snapshot?["policy"]?["maxSeats"]?.ToString() ?? "0";
            width.Text=snapshot?["policy"]?["width"]?.ToString() ?? "1920";
            height.Text=snapshot?["policy"]?["height"]?.ToString() ?? "1080";
            fps.Text=snapshot?["policy"]?["fps"]?.ToString() ?? "60";
            trayStartup.IsChecked=readTrayStartup();
            settingsBaseline=Draft(); settingsDirty=false; ValidateSettings(false);
        } finally { loadingSettings=false; UpdateSettingsState(); }
    }
    static void UpdateRows<T>(DataGrid grid,T[] rows,Func<T,string> identity) where T : class {
        // Keep existing rows when nothing changed, and reselect by identity when a status changes.
        if(grid.ItemsSource is T[] current && current.SequenceEqual(rows)) return;
        var selected = grid.SelectedItem is T item ? identity(item) : null;
        grid.ItemsSource=rows;
        grid.SelectedItem=rows.FirstOrDefault(row=>identity(row)==selected);
    }
    void SetPending(bool pending) {
        operationPending=pending;
        foreach(var button in actionButtons) button.IsEnabled=!pending;
        foreach(var control in new Control[]{boot,trayStartup,pause,normal,local,limits,width,height,fps,gameId,gameTitle,gameExe,games}) control.IsEnabled=!pending;
        foreach(var button in actionButtons.Where(b=>b.Tag is DataGrid)) button.IsEnabled=!pending && ((DataGrid)button.Tag).SelectedItem != null;
        UpdateSettingsState();
        UpdateFreshness(statusAvailable,runtimeHealthStale);
        UpdateConvenience(statusAvailable);
    }
    async Task<bool> ApplyAsync(JsonObject request,Action? afterSuccess=null) {
        if(operationPending) { ShowNotice("A host change is already in progress."); return false; }
        if(!statusAvailable) { ShowNotice("Refresh host status before making a change. The displayed information may be out of date.");return false; }
        SetPending(true); ShowNotice("Waiting for administrator approval and the host change to finish…");
        try {
            await applyRequest(request);
            if(request["operation"]?.ToString()=="game-save") { gameBaseline=GameDraft();editorGame=new Game(gameId.Text.Trim(),gameTitle.Text.Trim(),gameExe.Text.Trim()); }
            string message = request["operation"]?.ToString() switch {
                "settings" => "Hosting settings saved.", "policy" => "Hosting policy saved.",
                "runtime-start" => "Hosting start request completed.", "runtime-stop" => "Hosting stop request completed.",
                "seat-end" => "Selected desktop ended.", "repair" => "Selected stream repaired.",
                "game-save" => "Game saved to the shared library.", "game-remove" => "Game removed from the shared library.", _ => "Host change completed."
            };
            try { afterSuccess?.Invoke(); }
            catch(Exception ex) { message="Host settings saved, but Agent tray startup could not be saved: "+ex.Message; }
            bool refreshed=await Refresh(request["operation"]?.ToString()=="settings");
            ShowNotice(message+(refreshed ? "" : " Host status could not be refreshed. Refresh again to confirm the current settings."));
            return true;
        } catch(Win32Exception ex) when(ex.NativeErrorCode==1223) { ShowNotice("Administrator approval was cancelled. No change was submitted."); return false; }
        catch(Exception ex) { ShowNotice(ex is UnauthorizedAccessException or HostControlOfflineException or TimeoutException or OperationCanceledException or System.IO.IOException ? ControlFailure(ex).Help : ex.Message); return false; }
        finally { SetPending(false); }
    }
    async Task SaveAsync() {
        if(operationPending || !ValidateSettings(true)) return;
        if(snapshot == null) { ShowNotice("Connect to host control before saving settings."); return; }
        bool disabling = (snapshot["policy"]?["normalEnabled"]?.GetValue<bool>() != false && normal.IsChecked != true)
            || (snapshot["policy"]?["localEnabled"]?.GetValue<bool>() != false && local.IsChecked != true);
        if(disabling && !Confirm("Disabling a connection path disconnects its streams. Windows apps stay running. Continue?")) return;
        bool trayEnabled=trayStartup.IsChecked==true;
        var policy=new JsonObject{["paused"]=pause.IsChecked==true,["maxSeats"]=int.Parse(limits.Text),["width"]=int.Parse(width.Text),["height"]=int.Parse(height.Text),["fps"]=int.Parse(fps.Text),["normalEnabled"]=normal.IsChecked==true,["localEnabled"]=local.IsChecked==true};
        await ApplyAsync(new(){["operation"]="settings",["policy"]=policy,["startAtBoot"]=boot.IsChecked==true},()=>writeTrayStartup(trayEnabled));
    }
}
