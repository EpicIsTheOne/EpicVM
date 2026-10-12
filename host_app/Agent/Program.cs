using System.Diagnostics;
using System;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Security.Principal;
using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Microsoft.Win32;
using Application = System.Windows.Application;
using Button = System.Windows.Controls.Button;
using MessageBox = System.Windows.MessageBox;
using TextBox = System.Windows.Controls.TextBox;

namespace EpicVM.Desktop;

static class Rpc
{
    public static async Task<JsonObject> Call(JsonObject request) {
        using var pipe = new NamedPipeClientStream(".", "EpicVM.HostControl", PipeDirection.InOut, PipeOptions.Asynchronous, TokenImpersonationLevel.Impersonation);
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(25));
        try { await pipe.ConnectAsync(timeout.Token); }
        catch(OperationCanceledException ex) { throw new HostControlOfflineException(ex); }
        var bytes = Encoding.UTF8.GetBytes(request.ToJsonString()+"\n"); await pipe.WriteAsync(bytes, timeout.Token); await pipe.FlushAsync(timeout.Token);
        using var reader = new StreamReader(pipe); var line = await reader.ReadLineAsync(timeout.Token);
        if(line==null) throw new IOException("Host control closed the connection before responding.");
        var response = JsonNode.Parse(line)!.AsObject();
        if (response["ok"]?.GetValue<bool>() != true) throw new InvalidOperationException(response["error"]?.ToString() ?? "Host request failed.");
        return response["data"]!.DeepClone().AsObject();
    }
    public static async Task Apply(JsonObject request) {
        var info = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = true, Verb = "runas" };
        info.ArgumentList.Add("--apply"); info.ArgumentList.Add(Convert.ToBase64String(Encoding.UTF8.GetBytes(request.ToJsonString())));
        using var process = Process.Start(info) ?? throw new InvalidOperationException("Could not open the administrator request.");
        await WaitForResult(process);
    }
    internal static async Task WaitForResult(Process process) {
        await process.WaitForExitAsync();
        if(process.ExitCode != 0) throw new InvalidOperationException("The host change failed. Check the error shown by the administrator request, then refresh to confirm the current host settings.");
    }
}

sealed partial class AgentWindow : Window
{
    readonly TextBlock headline = new() { FontSize = 27, FontWeight = FontWeights.SemiBold };
    readonly TextBlock detail = new() { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0,12,0,12) };
    readonly TextBlock notice = new() { TextWrapping = TextWrapping.Wrap, Foreground = Brushes.LightSkyBlue, Margin = new Thickness(0,12,0,8) };
    readonly DataGrid seats = Grid(); readonly DataGrid resources = Grid(); readonly DataGrid games = Grid();
    readonly CheckBox boot = new() { Content = "Start hosting when Windows boots" };
    readonly CheckBox trayStartup = new() { Content = "Open Agent in the tray when I sign in" };
    readonly CheckBox pause = new() { Content = "Pause new desktops (existing desktops can reconnect)" };
    readonly CheckBox normal = new() { Content = "Allow normal connections" };
    readonly CheckBox local = new() { Content = "Allow local network connections" };
    readonly TextBox limits = Field("0"); readonly TextBox width = Field("1920"); readonly TextBox height = Field("1080"); readonly TextBox fps = Field("60");
    readonly TextBox gameId = Field(""); readonly TextBox gameTitle = Field(""); readonly TextBox gameExe = Field("");
    readonly TextBox diagnostics = new() { IsReadOnly = true, AcceptsReturn = true, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, FontFamily = new FontFamily("Consolas"), MinHeight = 300 };
    readonly System.Windows.Forms.NotifyIcon tray = new();
    readonly System.Windows.Threading.DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(5) };
    JsonObject? snapshot; bool refreshing;
    static DataGrid Grid() => new() { IsReadOnly = true, AutoGenerateColumns = false, MinHeight = 160, MaxHeight = 260, Margin = new Thickness(0,10,0,8), CanUserAddRows = false };
    static TextBox Field(string value) => new() { Text = value, MinWidth = 140, Padding = new Thickness(8), Margin = new Thickness(0,5,0,10) };
    static TextBlock Label(string text) => new() { Text = text, TextWrapping = TextWrapping.Wrap, Foreground = Ink("#A6AEC5"), FontSize = 13, Margin = new Thickness(0,6,0,10) };
    Button Action(string text, Action handler) { var b = new Button { Content = text, Padding = new Thickness(14,8,14,8), Margin = new Thickness(0,4,10,8) }; b.Click += (_,_)=>handler(); actionButtons.Add(b); return b; }
    static WrapPanel Row(params UIElement[] children) { var p = new WrapPanel(); foreach(var child in children) p.Children.Add(child); return p; }
    static StackPanel Page(TabControl tabs, string title, string description) {
        var panel = new StackPanel { Margin = new Thickness(28,24,28,28) };
        panel.Children.Add(Heading(title,28));
        var subtitle = Label(description); subtitle.Margin = new Thickness(0,0,0,24); panel.Children.Add(subtitle);
        tabs.Items.Add(new TabItem { Header = title, HorizontalContentAlignment = HorizontalAlignment.Stretch, Content = new ScrollViewer { Foreground = Ink("#F0F2FA"), FontWeight = FontWeights.Normal, HorizontalContentAlignment = HorizontalAlignment.Stretch, Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled } });
        return panel;
    }
    public AgentWindow(bool hidden, bool preview = false) {
        BuildLayout();
        InitializeInteractions();
        if(preview) return;
        tray.Icon=System.Drawing.SystemIcons.Application;tray.Text="EpicVM Agent";tray.Visible=true;tray.DoubleClick+=(_,_)=>Open();
        var menu=new System.Windows.Forms.ContextMenuStrip();menu.Items.Add(trayStatus);menu.Items.Add("Open Agent",null,(_,_)=>Open());trayPause.Click+=(_,_)=>ToggleTrayPause();menu.Items.Add(trayPause);menu.Items.Add("Quit Agent (hosting stays running)",null,(_,_)=>QuitAgent());tray.ContextMenuStrip=menu;
        UpdateConvenience(false);
        Closing+=(_,e)=>{e.Cancel=true;Hide();};timer.Tick+=(_,_)=>_ = Refresh();timer.Start();
        Loaded+=async(_,_)=>{if(hidden)Hide();await Refresh(true);};
    }
    void Open(){Show();WindowState=WindowState.Normal;Activate();}
    static bool Confirm(string message)=>MessageBox.Show(message,"EpicVM Agent",MessageBoxButton.YesNo,MessageBoxImage.Warning)==MessageBoxResult.Yes;
    void Apply(JsonObject req) => _ = ApplyAsync(req);
    void Save() => _ = SaveAsync();
    void Export(){if(snapshot==null)return;var dialog=new SaveFileDialog{Filter="JSON snapshot|*.json",FileName="EpicVM-support.json"};if(dialog.ShowDialog()==true)File.WriteAllText(dialog.FileName,snapshot.ToJsonString(new(){WriteIndented=true}));}
    async Task<bool> Refresh(bool fields=false){if(refreshing){if(!fields)return false;while(refreshing)await Task.Delay(25);}refreshing=true;try{
        snapshot=await readStatus(new(){["operation"]="status"});var runtime=snapshot["runtime"];var services=snapshot["services"];
        var updated=long.TryParse(runtime?["updatedAt"]?.ToString(),out var seconds)?seconds:0;
        bool stale=DateTimeOffset.UtcNow.ToUnixTimeSeconds()-updated>45;
        headline.Text=services?["Runtime"]?.ToString()!="Running"?"Hosting is stopped":stale?"Host status is stale":runtime?["state"]?.ToString()=="ready"?"Host runtime is ready":"Host needs attention";
        detail.Text=stale?"The runtime has not reported recent health. Check its service and network.":runtime?["message"]?.ToString();
        UpdateRows(seats,snapshot["seats"]!.AsArray().Select(s=>new Seat(s?["id"]?.ToString()??"",s?["accountName"]?.ToString()??"",s?["status"]?.ToString()??"")).ToArray(),s=>s.Id);
        UpdateRows(resources,snapshot["resources"]!.AsArray().Select(r=>new Resource(r!["route"]!.ToString(),r["enabled"]?.GetValue<bool>()==true)).ToArray(),r=>r.Route);
        updatingGameRows=true;
        try { UpdateRows(games,snapshot["games"]!.AsArray().Select(g=>new Game(g!["id"]!.ToString(),g["title"]!.ToString(),g["executable"]!.ToString())).ToArray(),g=>g.Id); }
        finally { updatingGameRows=false; }
        UpdateOverview();
        if(snapshot["seatError"] != null) { sessionEmpty.Text = snapshot["seatError"]!.ToString(); sessionEmpty.Visibility = Visibility.Visible; }
        else sessionEmpty.Text = "No desktops are running. Assigned desktops appear here when someone connects.";
        diagnostics.Text=snapshot.ToJsonString(new(){WriteIndented=true});
        if(fields || !settingsDirty) LoadSettings();
        lastSuccessfulUpdate=DateTimeOffset.Now;
        UpdateFreshness(true,stale);
        UpdateConvenience();
        UpdateVersions();
        return true;
    }catch(Exception ex){var failure=ControlFailure(ex);headline.Text=failure.Title;detail.Text=failure.Help;foreach(var value in values.Values)value.Text="Unavailable";UpdateFreshness(false);UpdateConvenience(false);return false;}finally{refreshing=false;}}
    public record Seat(string Id,string Account,string Status);public record Resource(string Route,bool Enabled);public record Game(string Id,string Title,string Executable);
}

static class Program
{
    [STAThread] static void Main(string[] args){
        if(args.Length==4 && args[0]=="--setup-operation") { Environment.ExitCode=SetupWindow.Operation(args[1],args[2],args[3]);return; }
        if(args.Length==2 && args[0]=="--setup-preview") {var appPreview=new Application();var setupPreview=new SetupWindow();setupPreview.Preview(args[1]);appPreview.Shutdown();return;}
        // Ordinary users cannot read protected runtime state. Service registration
        // distinguishes a fresh PC from an installed host without opening secrets.
        using var hostRegistration = Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Services\EpicVMHostControl");
        if(args.Contains("--setup") || (args.Length==0 && hostRegistration==null)) {new Application().Run(new SetupWindow());return;}
        if(args.Length==3 && args[0]=="--request-file") { try { var request=JsonNode.Parse(File.ReadAllText(args[1]))!.AsObject();File.WriteAllText(args[2],new JsonObject{["ok"]=true,["data"]=Rpc.Call(request).GetAwaiter().GetResult()}.ToJsonString()); }catch(Exception ex){File.WriteAllText(args[2],new JsonObject{["ok"]=false,["error"]=ex.Message}.ToJsonString());Environment.ExitCode=1;}return; }
        if(args.Length==2 && args[0]=="--status-file") { try { File.WriteAllText(args[1],Rpc.Call(new(){["operation"]="status"}).GetAwaiter().GetResult().ToJsonString()); }catch{Environment.ExitCode=1;}return; }
        if(args.Length==2 && args[0]=="--apply") { try { var req=JsonNode.Parse(Encoding.UTF8.GetString(Convert.FromBase64String(args[1])))!.AsObject();Rpc.Call(req).GetAwaiter().GetResult(); }catch(Exception ex){Environment.ExitCode=1;MessageBox.Show(ex.Message,"EpicVM host change failed");}return; }
        var app=new Application();
        if(args.Length == 2 && args[0] == "--preview-dir") { var preview = new AgentWindow(false,true); preview.RenderPreviews(args[1]); preview.Close(); app.Shutdown(); return; }
        using var instance=new AgentInstance();
        if(!instance.IsFirst) { if(!args.Contains("--tray"))instance.ActivateExisting(); return; }
        var window=new AgentWindow(args.Contains("--tray"));
        instance.Listen(()=>app.Dispatcher.BeginInvoke(new Action(()=>{window.Show();window.WindowState=WindowState.Normal;window.Activate();})));
        app.Run(window);
    }
}
