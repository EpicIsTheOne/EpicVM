using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Microsoft.Win32;
using Button = System.Windows.Controls.Button;

namespace EpicVM.Desktop;

sealed partial class AgentWindow
{
    readonly TabControl navigation = new();
    readonly Dictionary<string, TextBlock> values = new();
    readonly TextBlock sessionEmpty = Label("No desktops are running. Assigned desktops appear here when someone connects.");
    readonly TextBlock resourceEmpty = Label("No stream resources are registered yet.");
    readonly TextBlock gameEmpty = Label("Your shared game library is empty. Add an installed game below.");
    readonly TextBlock lanTrust = Label("");
    static SolidColorBrush Ink(string hex) => new((Color)ColorConverter.ConvertFromString(hex));
    static TextBlock Heading(string text, double size = 18) => new() { Text = text, FontSize = size, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0,0,0,8) };
    static Border Card(UIElement content) => new() { Background = Ink("#191D2B"), BorderBrush = Ink("#30364B"), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(12), Padding = new Thickness(20), Margin = new Thickness(0,0,0,16), Child = content };
    static StackPanel Section(string title, string description) {
        var panel = new StackPanel(); panel.Children.Add(Heading(title)); panel.Children.Add(Label(description)); return panel;
    }
    Button StyledAction(string text, Action handler, string style) { var button = Action(text,handler); button.Style = (Style)FindResource(style); return button; }
    void Column(DataGrid grid, string title, string property, double weight = 1) {
        grid.Columns.Add(new DataGridTextColumn { Header = title, Binding = new Binding(property), Width = new DataGridLength(weight,DataGridLengthUnitType.Star), MinWidth = 90 });
    }
    void Metric(Panel panel, string key, string title) {
        var stack = new StackPanel();
        stack.Children.Add(new TextBlock { Text = title, Foreground = Ink("#A6AEC5"), FontSize = 12 });
        var value = new TextBlock { Text = "Checking…", FontSize = 23, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0,9,0,0) };
        values.Add(key,value); stack.Children.Add(value);
        var card = Card(stack); card.Width = 205; card.Margin = new Thickness(0,0,12,12); panel.Children.Add(card);
    }
    void Info(Panel panel, string key, string title) {
        panel.Children.Add(Label(title));
        var value = new TextBlock { Text = "Checking…", FontSize = 14, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0,0,0,10) };
        values.Add(key,value); panel.Children.Add(value);
    }
    void BuildLayout() {
        Resources.MergedDictionaries.Add(new ResourceDictionary { Source = new Uri("/EpicVM.Agent;component/Theme.xaml",UriKind.Relative) });
        Title = "EpicVM Agent"; Width = 1100; Height = 820; MinWidth = 880; MinHeight = 620;
        Background = Ink("#10121B"); Foreground = Ink("#F0F2FA"); FontFamily = new FontFamily("Segoe UI"); FontSize = 14;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;

        var status = Page(navigation,"Overview","Your host, at a glance.");
        var health = new StackPanel();
        health.Children.Add(new TextBlock { Text = "HOST STATUS", Foreground = Ink("#A99BFF"), FontSize = 11, FontWeight = FontWeights.Bold, Margin = new Thickness(0,0,0,10) });
        headline.Text = "Checking your host…"; health.Children.Add(headline); health.Children.Add(detail); health.Children.Add(freshness);
        health.Children.Add(Row(StyledAction("Start hosting",()=>Apply(new(){["operation"]="runtime-start"}),"PrimaryButton"),
            Action("Refresh status",()=>_ = Refresh()),
            StyledAction("Stop hosting…",()=>{if(Confirm("Disconnect all streams? Windows apps will remain running."))Apply(new(){["operation"]="runtime-stop"});},"DangerButton")));
        status.Children.Add(Card(health));
        var metrics = new WrapPanel(); Metric(metrics,"desktops","ACTIVE DESKTOPS"); Metric(metrics,"admission","NEW DESKTOPS"); Metric(metrics,"boot","WINDOWS STARTUP"); status.Children.Add(metrics);
        var connection = Section("Connections","Connection details and access for this host.");
        Info(connection,"host","Host name"); Info(connection,"normal","Normal connection"); LinkActions(connection,"normal"); Info(connection,"local","Local network"); LinkActions(connection,"local"); status.Children.Add(Card(connection));
        connection.Children.Add(Label("These are host gateway addresses. Open your assigned desktop from the EpicVM portal to start streaming."));
        lanTrust.Visibility=Visibility.Collapsed;connection.Children.Add(lanTrust);
        var service = Section("Host services","Live status updates every five seconds.");
        foreach(var key in new[]{"Runtime","Agent","MultiSeat","Tailscale"}) Info(service,key,key == "Agent" ? "Remote agent" : key);
        Info(service,"portal","Portal synchronization"); status.Children.Add(Card(service));

        var sessions = Page(navigation,"Sessions","Manage Windows desktops and their streams.");
        sessions.Children.Add(sessionFreshness);
        Column(seats,"Windows account","Account",2); Column(seats,"Status","Status");
        Column(resources,"Stream resource","Route",3); Column(resources,"Enabled","Enabled");
        var desktops = Section("Windows desktops","Ending a desktop closes that account's open Windows apps.");
        desktops.Children.Add(seats); desktops.Children.Add(sessionEmpty);
        var end = StyledAction("End selected desktop…",()=>{if(seats.SelectedItem is Seat s && Confirm($"End {s.Account}'s desktop? Their open Windows apps will close."))Apply(new(){["operation"]="seat-end",["seatId"]=s.Id});},"DangerButton");
        end.Tag = seats; end.IsEnabled = false; seats.SelectionChanged += (_,_)=>end.IsEnabled = statusAvailable && !operationPending && seats.SelectedItem is Seat; desktops.Children.Add(end); sessions.Children.Add(Card(desktops));
        var streams = Section("Stream resources","Repair disconnects viewers and recovers the stream. Windows apps stay running.");
        streams.Children.Add(resources); streams.Children.Add(resourceEmpty);
        var repair = Action("Repair selected stream…",()=>{if(resources.SelectedItem is Resource r && Confirm($"Disconnect viewers of {r.Route} and recover its streaming process?"))Apply(new(){["operation"]="repair",["route"]=r.Route});});
        repair.Tag = resources; repair.IsEnabled = false; resources.SelectionChanged += (_,_)=>repair.IsEnabled = statusAvailable && !operationPending && resources.SelectedItem is Resource;
        streams.Children.Add(repair); sessions.Children.Add(Card(streams));

        var settings = Page(navigation,"Hosting","Choose how this PC shares desktops.");
        settings.Children.Add(settingsState);
        var startup = Section("Startup & availability","Hosting can start before you sign in to Windows.");
        foreach(var control in new UIElement[]{boot,trayStartup,pause}) startup.Children.Add(control); settings.Children.Add(Card(startup));
        var access = Section("Connection paths","Choose how friends can reach their desktops."); access.Children.Add(normal); access.Children.Add(local); settings.Children.Add(Card(access));
        var defaults = Section("Desktop defaults","Resolution and frame rate apply to newly created desktops.");
        foreach(var control in new UIElement[]{Label("Maximum desktops (0 means unlimited)"),InputWithError(limits),Label("Default resolution"),Label("Width"),InputWithError(width),Label("Height"),InputWithError(height),Label("Frames per second: 30, 60 or 120"),InputWithError(fps)}) defaults.Children.Add(control);
        settings.Children.Add(Card(defaults)); saveSettings = StyledAction("Save hosting settings",Save,"PrimaryButton"); settings.Children.Add(saveSettings);
        settings.Children.Add(Label("Host changes require Windows administrator approval. Startup changes apply at the next boot."));

        var catalog = Page(navigation,"Games","Build the game library your friends can launch.");
        Column(games,"Game","Title",1); Column(games,"Executable","Executable",2);
        var library = Section("Shared library","Installed games available through EpicVM."); library.Children.Add(games); library.Children.Add(gameEmpty);
        var remove = StyledAction("Remove selected game…",()=>{if(games.SelectedItem is Game g && Confirm($"Remove {g.Title} from the shared catalog? Installed files stay on disk."))Apply(new(){["operation"]="game-remove",["id"]=g.Id});},"DangerButton");
        remove.Tag = games; remove.IsEnabled = false; games.SelectionChanged += (_,_)=>remove.IsEnabled = statusAvailable && !operationPending && games.SelectedItem is Game; library.Children.Add(remove); catalog.Children.Add(Card(library));
        var editor = Section("Add or update a game","Choose the executable installed on this PC.");
        foreach(var control in new UIElement[]{Label("Game ID (lowercase letters, numbers, hyphens)"),InputWithError(gameId),Label("Title"),InputWithError(gameTitle),Label("Installed executable"),InputWithError(gameExe)}) editor.Children.Add(control);
        editor.Children.Add(Row(Action("Browse…",()=>{var dialog=new OpenFileDialog{Filter="Executables|*.exe"};if(dialog.ShowDialog()==true)gameExe.Text=dialog.FileName;}),
            Action("New game",NewGame),
            StyledAction("Add or update game",SaveGame,"PrimaryButton")));
        catalog.Children.Add(Card(editor));

        var logs = Page(navigation,"Diagnostics","Host details when you need to troubleshoot.");
        var support = Section("Support snapshot","Status and configuration summaries, without credentials or private pairing data.");
        support.Children.Add(diagnostics); support.Children.Add(Action("Export support snapshot…",Export)); logs.Children.Add(Card(support));
        BuildUpdates();
        notice.Visibility = Visibility.Collapsed;
        var root = new DockPanel { Background = Ink("#10121B") }; var banner = new Border { Child = notice, Background = Ink("#25233A"), Padding = new Thickness(20,8,20,8) };
        banner.SetBinding(VisibilityProperty,new Binding("Visibility") { Source = notice });
        DockPanel.SetDock(banner,Dock.Bottom); root.Children.Add(banner); root.Children.Add(navigation); Content = root;
    }
    void ShowNotice(string message) { notice.Text = message; notice.Visibility = Visibility.Visible; }
    void UpdateOverview() {
        if(snapshot == null) return;
        values["desktops"].Text = snapshot["seats"]?.AsArray().Count.ToString() ?? "0";
        values["admission"].Text = snapshot["policy"]?["paused"]?.GetValue<bool>() == true ? "Paused" : "Allowed";
        values["boot"].Text = snapshot["startAtBoot"]?.GetValue<bool>() == true ? "Automatic" : "Manual";
        values["host"].Text = snapshot["hostId"]?.ToString() ?? "Unavailable";
        values["normal"].Text = snapshot["policy"]?["normalEnabled"]?.GetValue<bool>() == false ? "Disabled in hosting settings" : snapshot["publicOrigin"]?.ToString() ?? "Not configured";
        values["local"].Text = snapshot["policy"]?["localEnabled"]?.GetValue<bool>() == false ? "Disabled in hosting settings" : ConnectionLink("local") ?? "Not configured";
        lanTrust.Visibility=snapshot["lan"]?["clientTrustRequired"]?.GetValue<bool>()==true?Visibility.Visible:Visibility.Collapsed;
        lanTrust.Text="One-time client certificate trust required.\nPublic certificate setup: "+snapshot["lan"]?["setupUrl"]+"\nCompare this SHA256 fingerprint before trusting it:\n"+snapshot["lan"]?["certificateSha256"];
        foreach(var key in new[]{"Runtime","Agent","MultiSeat","Tailscale"}) {
            values[key].Text = snapshot["services"]?[key]?.ToString() ?? "Unavailable";
            values[key].FontSize = 14; values[key].Foreground = Ink(values[key].Text == "Running" ? "#89DEBD" : "#FFCC8A");
        }
        values["portal"].Text = snapshot["runtime"]?["portal"]?.ToString() ?? "Unavailable";
        sessionEmpty.Visibility = seats.Items.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        resourceEmpty.Visibility = resources.Items.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        gameEmpty.Visibility = games.Items.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }
    internal void RenderPreviews(string directory) {
        Directory.CreateDirectory(directory);
        headline.Text = "Your host is ready"; detail.Text = "Ready for friends to connect. Hosting runs independently of your Windows login.";
        foreach(var key in values.Keys) values[key].Text = key switch { "desktops" => "2", "admission" => "Allowed", "boot" => "Automatic", "host" => "My gaming PC", "normal" => "https://host.example.com", "local" => "Enabled · same network as this PC", "portal" => "Connected", _ => "Running" };
        seats.ItemsSource = new[]{new Seat("preview-1","EpicVM_friend","Ready"),new Seat("preview-2","LocalPlayer","Ready")};
        resources.ItemsSource = new[]{new Resource("desktop-friend",true)};
        games.ItemsSource = new[]{new Game("sample-game","Sample game",@"C:\Games\Sample\game.exe")};
        sessionEmpty.Visibility = resourceEmpty.Visibility = gameEmpty.Visibility = Visibility.Collapsed;
        boot.IsChecked = trayStartup.IsChecked = normal.IsChecked = local.IsChecked = true;
        settingsBaseline=Draft(); settingsDirty=false; UpdateSettingsState();
        Show();
        foreach(var index in Enumerable.Range(0,navigation.Items.Count)) {
            navigation.SelectedIndex = index; UpdateLayout();
            Dispatcher.Invoke(()=>{},System.Windows.Threading.DispatcherPriority.ContextIdle);
            var visual = (FrameworkElement)Content;
            var bitmap = new RenderTargetBitmap((int)visual.ActualWidth,(int)visual.ActualHeight,96,96,PixelFormats.Pbgra32); bitmap.Render(visual);
            var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap));
            using var output = File.Create(Path.Combine(directory,$"agent-{index}.png")); encoder.Save(output);
        }
        Width = MinWidth; Height = MinHeight; navigation.SelectedIndex = 2; UpdateLayout();
        Dispatcher.Invoke(()=>{},System.Windows.Threading.DispatcherPriority.ContextIdle);
        var compact = (FrameworkElement)Content;
        var compactBitmap = new RenderTargetBitmap((int)compact.ActualWidth,(int)compact.ActualHeight,96,96,PixelFormats.Pbgra32); compactBitmap.Render(compact);
        var compactEncoder = new PngBitmapEncoder(); compactEncoder.Frames.Add(BitmapFrame.Create(compactBitmap));
        using var compactOutput = File.Create(Path.Combine(directory,"agent-compact.png")); compactEncoder.Save(compactOutput);
        fps.Text="45";
        if(((TabItem)navigation.Items[2]).Content is ScrollViewer hostingScroll) hostingScroll.ScrollToEnd();
        UpdateLayout(); Dispatcher.Invoke(()=>{},System.Windows.Threading.DispatcherPriority.ContextIdle);
        var validationBitmap = new RenderTargetBitmap((int)compact.ActualWidth,(int)compact.ActualHeight,96,96,PixelFormats.Pbgra32); validationBitmap.Render(compact);
        var validationEncoder = new PngBitmapEncoder(); validationEncoder.Frames.Add(BitmapFrame.Create(validationBitmap));
        using var validationOutput = File.Create(Path.Combine(directory,"agent-validation.png")); validationEncoder.Save(validationOutput);
        navigation.SelectedIndex=1;lastSuccessfulUpdate=DateTimeOffset.Now.AddMinutes(-2);
        var failure=ControlFailure(new HostControlOfflineException(new TimeoutException()));headline.Text=failure.Title;detail.Text=failure.Help;
        UpdateFreshness(false);UpdateConvenience(false);UpdateLayout();Dispatcher.Invoke(()=>{},System.Windows.Threading.DispatcherPriority.ContextIdle);
        var staleBitmap=new RenderTargetBitmap((int)compact.ActualWidth,(int)compact.ActualHeight,96,96,PixelFormats.Pbgra32);staleBitmap.Render(compact);
        var staleEncoder=new PngBitmapEncoder();staleEncoder.Frames.Add(BitmapFrame.Create(staleBitmap));
        using var staleOutput=File.Create(Path.Combine(directory,"agent-stale-sessions.png"));staleEncoder.Save(staleOutput);
        navigation.SelectedIndex=3;gameId.Text="BAD ID";gameTitle.Clear();gameExe.Text=@"C:\Games\missing.exe";ValidateGame(false);
        if(((TabItem)navigation.Items[3]).Content is ScrollViewer gameScroll)gameScroll.ScrollToEnd();
        UpdateLayout();Dispatcher.Invoke(()=>{},System.Windows.Threading.DispatcherPriority.ContextIdle);
        var gameBitmap=new RenderTargetBitmap((int)compact.ActualWidth,(int)compact.ActualHeight,96,96,PixelFormats.Pbgra32);gameBitmap.Render(compact);
        var gameEncoder=new PngBitmapEncoder();gameEncoder.Frames.Add(BitmapFrame.Create(gameBitmap));
        using var gameOutput=File.Create(Path.Combine(directory,"agent-game-validation.png"));gameEncoder.Save(gameOutput);
    }
}
