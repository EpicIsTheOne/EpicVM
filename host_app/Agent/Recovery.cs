using System;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;

namespace EpicVM.Desktop;

sealed class HostControlOfflineException : IOException
{
    public HostControlOfflineException(Exception inner) : base("Host control is not responding to new connections.",inner) { }
}

sealed partial class AgentWindow
{
    readonly TextBlock freshness = Label("Waiting for the first host update…");
    readonly TextBlock sessionFreshness = Label("Waiting for current session data…");
    DateTimeOffset? lastSuccessfulUpdate;
    bool statusAvailable;
    bool runtimeHealthStale;
    Func<string,bool> gameFileExists = File.Exists;
    static (string Title,string Help) ControlFailure(Exception ex) => ex switch {
        UnauthorizedAccessException => ("Access to host control was denied","Use the Windows account enrolled as the EpicVM operator. If this is that account, ask the host administrator to check its operator permissions."),
        Win32Exception win when win.NativeErrorCode==5 => ("Access to host control was denied","Use the enrolled operator account or ask the host administrator to check its permissions."),
        HostControlOfflineException => ("Host control is offline or busy","Open Windows Services and check that EpicVM Host Control is running, then refresh. This does not mean your Windows desktops have stopped."),
        TimeoutException or OperationCanceledException => ("Host control took too long to respond","Wait a moment and refresh. If this repeats, check EpicVM Host Control in Windows Services. Keep existing desktops running while investigating."),
        IOException => ("The host control connection was interrupted","Refresh to reconnect. If this repeats, check EpicVM Host Control in Windows Services."),
        _ => ("Host status could not be read","Refresh again. If it keeps failing, export the last support snapshot and check the host services.")
    };
    void UpdateFreshness(bool available,bool runtimeStale=false) {
        statusAvailable=available;
        runtimeHealthStale=runtimeStale;
        var stamp=lastSuccessfulUpdate?.ToLocalTime().ToString("HH:mm:ss") ?? "never";
        freshness.Text=available ? "Last status update: "+stamp+(runtimeStale ? " · Runtime health is stale." : " · Live host data.") : "Last successful update: "+stamp+" · Host data is unavailable.";
        sessionFreshness.Text=available ? "Session data updated at "+stamp+"." : lastSuccessfulUpdate==null ? "No session data received yet." : "Showing last known sessions from "+stamp+". Their current status is unknown.";
        freshness.Foreground=sessionFreshness.Foreground=Ink(available && !runtimeStale ? "#A6AEC5" : "#FFCC8A");
        foreach(var grid in new[]{seats,resources,games}) { grid.Opacity=available ? 1 : 0.55;grid.IsEnabled=available && !operationPending; }
        foreach(var button in actionButtons.Where(b=>b.Tag is DataGrid)) button.IsEnabled=available && !operationPending && ((DataGrid)button.Tag).SelectedItem!=null;
        UpdateSettingsState();
    }
    bool ValidateGame(bool focus=true) {
        TextBox? first=null;
        void Check(TextBox field,bool valid,string message) {
            fieldErrors[field].Text=valid ? "" : message;
            fieldErrors[field].Visibility=valid ? Visibility.Collapsed : Visibility.Visible;
            field.BorderBrush=Ink(valid ? "#30364B" : "#FFB2BF");
            if(!valid) first ??= field;
        }
        Check(gameId,Regex.IsMatch(gameId.Text.Trim(),"^[a-z0-9][a-z0-9-]{0,63}$"),"Use 1–64 lowercase letters, numbers or hyphens, starting with a letter or number.");
        Check(gameTitle,!string.IsNullOrWhiteSpace(gameTitle.Text) && gameTitle.Text.Trim().Length<=120,"Enter a title of 1–120 characters.");
        string path=gameExe.Text.Trim(),error="Choose an existing machine-installed .exe file using Browse.";
        bool valid=false;
        try {
            if(Path.IsPathFullyQualified(path) && !path.StartsWith(@"\\") && !path.StartsWith(@"\?\") && path.EndsWith(".exe",StringComparison.OrdinalIgnoreCase)) {
                path=Path.GetFullPath(path);
                if(Regex.IsMatch(path,@"\\(Users|AppData|Windows)\\",RegexOptions.IgnoreCase)) error="Choose a machine-installed game outside Users, AppData and Windows folders.";
                else valid=gameFileExists(path);
            }
        }catch(Exception ex) when(ex is ArgumentException or NotSupportedException or IOException or UnauthorizedAccessException) { }
        Check(gameExe,valid,error);
        if(first!=null && focus) { navigation.SelectedIndex=3;first.Focus();first.BringIntoView(); }
        return first==null;
    }
    void SaveGame() {
        if(operationPending || !ValidateGame()) return;
        Apply(new(){["operation"]="game-save",["id"]=gameId.Text.Trim(),["title"]=gameTitle.Text.Trim(),["executable"]=Path.GetFullPath(gameExe.Text.Trim())});
    }
}
