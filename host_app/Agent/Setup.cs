using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Security.AccessControl;
using System.Security.Principal;
using Microsoft.Win32;
using Button = System.Windows.Controls.Button;
using TextBox = System.Windows.Controls.TextBox;
namespace EpicVM.Desktop;

sealed partial class SetupWindow : Window {
    readonly ComboBox layout = new() { ItemsSource = new[]{"Portal on this PC", "Connect to my separate server"}, SelectedIndex=0, Margin=new Thickness(0,5,0,12) };
    readonly TextBox portal = Field("https://portal.example.com"), stream=Field("https://stream.example.com"), host=Field("my-pc"), name=Field(Environment.MachineName), agent=Field("http://127.0.0.1:8765"), admin=Field("admin");
    readonly PasswordBox password = new() { Padding=new Thickness(8), Margin=new Thickness(0,5,0,12) };
    readonly TextBox status = new() { IsReadOnly=true, TextWrapping=TextWrapping.Wrap, AcceptsReturn=true, MinHeight=180, VerticalScrollBarVisibility=ScrollBarVisibility.Auto, Margin=new Thickness(0,15,0,0) };
    readonly StackPanel actions = new(); bool busy;
    readonly TextBlock stepTitle=new(){FontSize=21,FontWeight=FontWeights.SemiBold,Margin=new Thickness(0,18,0,8)};
    readonly TextBlock stepHelp=new(){TextWrapping=TextWrapping.Wrap,Margin=new Thickness(0,0,0,15)};
    readonly Button next=new(){Padding=new Thickness(14),Margin=new Thickness(0,8,0,8)};
    readonly StackPanel fields=new();
    readonly StackPanel configurationFields=new();
    readonly TextBox dataRoot=Field(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),"EpicVM")), lanAddress=Field("");
    readonly StackPanel lanFields=new();
    int step;
    string[] Journey => layout.SelectedIndex==0
        ? new[]{"Check","Prepare","InstallComponents","InstallPortal","InstallGateway","CheckConnectivity","Enroll","Poll","InstallRuntime","ConfigureLan","CheckConnectivity","ConnectionCheck","Finish"}
        : new[]{"Check","Prepare","InstallComponents","ServerGuide","CheckConnectivity","Enroll","Poll","InstallGateway","InstallRuntime","ConfigureLan","CheckConnectivity","ConnectionCheck","Finish"};
    static TextBox Field(string s) => new() {Text=s,Padding=new Thickness(8),Margin=new Thickness(0,5,0,12)};
    static string PackageRoot() {
        var dir=new DirectoryInfo(AppContext.BaseDirectory);
        while(dir!=null) { if(File.Exists(Path.Combine(dir.FullName,"scripts","Setup-EpicVMFreshHost.ps1")))return dir.FullName;dir=dir.Parent; }
        throw new InvalidOperationException("Fresh-host setup files are missing from this package.");
    }
    public SetupWindow() {
        Resources.MergedDictionaries.Add(new ResourceDictionary { Source=new Uri("/EpicVM.Agent;component/Theme.xaml",UriKind.Relative) });
        Background=(Brush)Resources["Canvas"];Foreground=(Brush)Resources["Text"];
        next.Style=(Style)Resources["PrimaryButton"];
        password.Background=(Brush)Resources["Field"];password.Foreground=(Brush)Resources["Text"];password.BorderBrush=(Brush)Resources["Stroke"];
        Title="EpicVM Host Setup";Width=760;Height=820;MinWidth=550;MinHeight=600;
        var body=new StackPanel {Margin=new Thickness(28)};
        Content=new ScrollViewer {Content=body,VerticalScrollBarVisibility=ScrollBarVisibility.Auto};
        body.Children.Add(new TextBlock {Text="Set up your own EpicVM",FontSize=28,FontWeight=FontWeights.SemiBold});
        body.Children.Add(new TextBlock {Text="Choose where your portal runs. Setup keeps each instance's accounts and credentials separate. Existing hosts use their update or repair path.",TextWrapping=TextWrapping.Wrap,Margin=new Thickness(0,10,0,20)});
        Add(fields,"Deployment layout",layout);Add(configurationFields,"Your portal HTTPS address",portal);Add(configurationFields,"Your streaming HTTPS address",stream);Add(configurationFields,"Host ID",host);Add(configurationFields,"Host display name",name);Add(configurationFields,"Private agent address (port 8765)",agent);
        layout.SelectionChanged+=(_,_)=>{agent.Text=layout.SelectedIndex==0?"http://127.0.0.1:8765":"http://100.64.0.1:8765";admin.IsEnabled=password.IsEnabled=layout.SelectedIndex==0;UpdateStep();};
        Add(configurationFields,"First administrator (same-PC portal only)",admin);Add(configurationFields,"Administrator password (at least 12 characters)",password);
        Add(configurationFields,"EpicVM data folder (fixed NTFS drive)",dataRoot);
        var browse=new Button {Content="Choose data folder",Padding=new Thickness(8),Margin=new Thickness(0,0,0,12)};
        browse.Click+=(_,_)=>{var dialog=new OpenFolderDialog {Title="Choose an empty EpicVM data folder"};if(dialog.ShowDialog(this)==true)dataRoot.Text=dialog.FolderName;};configurationFields.Children.Add(browse);
        configurationFields.Children.Add(new TextBlock {Text="Stores runtime, hosting catalog and same-PC portal data. Windows profiles stay in their existing location. Saved storage cannot be moved by this wizard.",TextWrapping=TextWrapping.Wrap});
        fields.Children.Add(configurationFields);
        Add(lanFields,"Host LAN IPv4 address (leave blank to detect automatically)",lanAddress);
        var skip=new Button {Content="Skip local connection",Padding=new Thickness(10)};
        skip.Click+=(_,_)=>{if(!busy && Journey[step]=="ConfigureLan"){step++;UpdateStep();}};lanFields.Children.Add(skip);
        body.Children.Add(lanFields);
        body.Children.Add(stepTitle);body.Children.Add(stepHelp);body.Children.Add(fields);body.Children.Add(next);
        next.Click+=async(_,_)=>await Advance();
        AddButton("Resume saved setup",()=>Run("Status"));
        AddButton("Open my portal",()=>OpenPortal());
        AddButton("Recheck connectivity",()=>Run("CheckConnectivity"));
        AddButton("Open setup guide",()=>{try{Process.Start(new ProcessStartInfo(Path.Combine(PackageRoot(),"docs","FRESH-HOST-SETUP.md")){UseShellExecute=true});}catch(Exception ex){status.Text=ex.Message;}});
        body.Children.Add(actions);body.Children.Add(status);
        status.Text="Setup is incomplete until all components are installed and real video and input are verified. A running portal alone does not verify streaming.";
        UpdateStep();
    }
    static void Add(StackPanel p,string text,UIElement field){p.Children.Add(new TextBlock {Text=text,FontWeight=FontWeights.SemiBold});p.Children.Add(field);}
    void AddButton(string text,Func<Task> fn){var b=new Button {Content=text,Margin=new Thickness(0,3,0,3),Padding=new Thickness(10)};b.Click+=async(_,_)=>await fn();actions.Children.Add(b);}
    void AddButton(string text,Action fn)=>AddButton(text,()=>{fn();return Task.CompletedTask;});
    void OpenPortal(){try{var uri=new Uri(portal.Text.Trim());if(uri.Scheme!="https" || uri.UserInfo!="" || uri.AbsolutePath!="/")throw new Exception("Use a valid portal HTTPS origin.");Process.Start(new ProcessStartInfo(uri.GetLeftPart(UriPartial.Authority)+"/EpicVM/Management?section=hosts"){UseShellExecute=true});}catch(Exception ex){status.Text=ex.Message;}}
    void UpdateStep(){
        var action=Journey[Math.Min(step,Journey.Length-1)];
        stepTitle.Text=$"Step {step+1} of {Journey.Length}: {TitleFor(action)}";
        stepHelp.Text=action switch {
            "Check"=>"Choose your layout. Setup checks the package before making changes. Your PC must stay powered on to host desktops.",
            "Prepare"=>"Save unique private instance credentials. Administrator access is required. Use a local Windows account to run this setup.",
            "InstallComponents"=>"Install verified desktop and controller components. Healthy installed components are retained. If a reboot is needed, save your work and reboot yourself, then resume here.",
            "InstallPortal"=>"Install your portal as a Windows boot service. Your administrator password was saved privately during preparation.",
            "InstallGateway"=>"Start automatic HTTPS. Point your streaming hostname here; for same-PC hosting, point your portal hostname here too. Public access requires TCP 80/443 to reach this PC. Existing proxy conflicts stop setup safely.",
            "ServerGuide"=>"Set up the separate Linux server using the included guide. Join the server and this PC to your private tailnet and allow only the intended management and pairing ports.",
            "CheckConnectivity"=>"Check trusted HTTPS and the portal identity. This checks reachability from this PC. Real streaming and access from another network still need their own checks.",
            "Enroll"=>"Request approval, then sign in to your portal as administrator. Match the displayed code before approving this host.",
            "Poll"=>"Approve this PC in your portal, then check approval here. Pending requests stay on this step; expired requests have a retry action.",
            "InstallRuntime"=>"Install host-specific runtime credentials and automatic boot services. Friends cannot connect until the desktop check passes and you activate this host.",
            "ConfigureLan"=>"Optional: create fully local HTTPS without a domain or router DNS changes. Each client must trust this host certificate once. Compare its fingerprint in the signed-in portal before trusting it. You can skip this and use the normal connection.",
            "ConnectionCheck"=>"Open Host setup approvals in your portal and start its desktop check. Confirm changing video and keyboard/mouse input, record the check, and activate the host. Then check activation here.",
            _=>"Your host is activated. Before relying on unattended hosting, save your work, reboot and connect while Windows remains at its sign-in screen. Also test from the network your guests will use. These checks are not certified by this wizard."
        };
        next.Content=action=="Finish"?"Open my portal":action=="ConnectionCheck"?"Check activation":TitleFor(action);
        fields.Visibility=step<2?Visibility.Visible:Visibility.Collapsed;
        configurationFields.Visibility=step==1?Visibility.Visible:Visibility.Collapsed;
        lanFields.Visibility=action=="ConfigureLan"?Visibility.Visible:Visibility.Collapsed;
    }
    static string TitleFor(string action)=>action switch {
        "Check"=>"Check compatibility","Prepare"=>"Save setup","InstallComponents"=>"Install hosting components",
        "InstallPortal"=>"Install portal","InstallGateway"=>"Configure HTTPS","ServerGuide"=>"Open server guide",
        "CheckConnectivity"=>"Check connectivity","Enroll"=>"Request host approval","Poll"=>"Check approval",
        "InstallRuntime"=>"Install boot services","ConfigureLan"=>"Set up local connection","ConnectionCheck"=>"Verify desktop connection",_=>"Finish setup"
    };
    async Task Advance(){
        var action=Journey[step];
        if(action=="Finish"){OpenPortal();return;}
        if(action=="ServerGuide"){
            try{Process.Start(new ProcessStartInfo(Path.Combine(PackageRoot(),"docs","FRESH-HOST-SETUP.md")){UseShellExecute=true});step++;UpdateStep();}catch(Exception ex){status.Text=ex.Message;}
            return;
        }
        await Run(action=="ConnectionCheck"?"Poll":action,true);
    }
    async Task Run(string action,bool advance=false) {
        if(busy)return;busy=true;actions.IsEnabled=next.IsEnabled=false;
        try {
            string scratch=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"EpicVM","setup");Directory.CreateDirectory(scratch);
            string input=Path.Combine(scratch,"input-"+Guid.NewGuid().ToString("N")+".json"),result=Path.Combine(scratch,"result-"+Guid.NewGuid().ToString("N")+".json");
            try {
                if(action=="Prepare") {
                    var config=new JsonObject { ["layout"]=layout.SelectedIndex==0?"same-pc":"separate-server",["portalOrigin"]=portal.Text.Trim(),["publicOrigin"]=stream.Text.Trim(),["hostId"]=host.Text.Trim(),["displayName"]=name.Text.Trim(),["agentUrl"]=agent.Text.Trim(),["adminUsername"]=admin.Text.Trim(),["adminPassword"]=password.Password,["dataRoot"]=dataRoot.Text.Trim(),["operatorSid"]=WindowsIdentity.GetCurrent().User!.Value };
                    using(File.Create(input)){}
                    var acl=new FileSecurity();acl.SetAccessRuleProtection(true,false);
                    foreach(var sid in new[]{WindowsIdentity.GetCurrent().User!.Value,"S-1-5-18","S-1-5-32-544"})acl.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(sid),FileSystemRights.FullControl,AccessControlType.Allow));
                    new FileInfo(input).SetAccessControl(acl);
                    File.WriteAllText(input,config.ToJsonString());
                }
                if(action=="ConfigureLan")File.WriteAllText(input,new JsonObject {["address"]=lanAddress.Text.Trim()}.ToJsonString());
                var info=new ProcessStartInfo(Environment.ProcessPath!) {UseShellExecute=true};
                if(action!="Check")info.Verb="runas";
                foreach(var arg in new[]{"--setup-operation",action,input,result})info.ArgumentList.Add(arg);
                status.Text="Running "+action+". Your setup state is saved privately for retry.";
                using var process=Process.Start(info)??throw new Exception("Could not start setup.");await process.WaitForExitAsync();
                var raw=File.Exists(result)?File.ReadAllText(result):"Setup did not return a result. It may have been cancelled.";
                JsonObject? report=null;
                try{report=JsonNode.Parse(raw.Trim())?.AsObject();}catch{}
                if(report==null)foreach(var line in raw.Split('\n').Reverse()){try{report=JsonNode.Parse(line.Trim())?.AsObject();if(report!=null)break;}catch{}}
                var data=report?["data"] as JsonObject ?? report;
                bool succeeded=process.ExitCode==0&&report?["ok"]?.GetValue<bool>()==true;
                status.Text=succeeded?(data?["message"]?.ToString()??TitleFor(action)+" completed."):"Setup incomplete\n"+(report?["error"]?.ToString()??raw);
                if(data?["code"]!=null)status.Text+="\nApproval code: "+data["code"];
                if(data?["state"]!=null)status.Text+="\nHost approval: "+data["state"];
                if(data?["rebootRequired"]?.GetValue<bool>()==true){status.Text+="\nSave your work, reboot, then resume this step.";succeeded=false;}
                if(action=="Check"&&report?["ready"]?.GetValue<bool>()!=true){succeeded=false;status.Text+="\nPackage prerequisites are missing. Use the complete host release package.";}
                if(action=="Check"&&report?["checks"] is JsonArray checkList){
                    foreach(var check in checkList){if(check?["ready"]?.GetValue<bool>()==false)status.Text+="\nMissing: "+check["name"];if(check?["existing"]?.GetValue<bool>()==true)status.Text+="\nExisting host detected. Use About & updates in your installed Agent; fresh setup will preserve it.";}
                }
                if(action=="Status"&&succeeded&&data!=null){
                    var c=data["configuration"]!;
                    layout.SelectedIndex=c["layout"]?.ToString()=="same-pc"?0:1;
                    portal.Text=c["portalOrigin"]!.ToString();stream.Text=c["publicOrigin"]!.ToString();host.Text=c["hostId"]!.ToString();name.Text=c["displayName"]!.ToString();agent.Text=c["agentUrl"]!.ToString();
                    dataRoot.Text=c["dataRoot"]?.ToString()??dataRoot.Text;
                    step=data["stage"]?.ToString() switch {"prepared"=>2,"awaiting-approval"=>Array.IndexOf(Journey,"Poll"),"enrolled"=>Array.IndexOf(Journey,"InstallRuntime"),"runtime-prepared"=>Array.IndexOf(Journey,"InstallRuntime"),"runtime-installed"=>Array.IndexOf(Journey,data["lanConfigured"]?.GetValue<bool>()==true?"ConnectionCheck":"ConfigureLan"),_=>0};
                }
                if(action=="Poll"&&data?["state"]?.ToString()!="enrolled")succeeded=false;
                if(action=="Poll"&&data?["state"]?.ToString()=="expired"){step=Array.IndexOf(Journey,"Enroll");status.Text+="\nRequest approval again. Your instance credentials are retained.";}
                if(advance&&action=="CheckConnectivity"&&step>Array.IndexOf(Journey,"InstallRuntime")&&data?["gatewayHttps"]?.GetValue<bool>()!=true){succeeded=false;status.Text+="\nThe streaming HTTPS gateway is not reachable yet. Check its hostname and certificate.";}
                if(advance&&Journey[step]=="ConnectionCheck"&&data?["activated"]?.GetValue<bool>()!=true){succeeded=false;OpenPortal();status.Text+="\nComplete the connection check and activate your host in the portal.";}
                if(advance&&succeeded)step=Math.Min(step+1,Journey.Length-1);
                if(action=="ConfigureLan"&&succeeded)status.Text+="\nLocal link: "+data?["origin"]+"\nClient trust page: "+data?["setupUrl"]+"\nCertificate SHA256: "+data?["certificateSha256"];
                if(action=="Prepare"&&succeeded)password.Clear();
                if(action=="Enroll"&&succeeded)OpenPortal();
                UpdateStep();
            } finally {if(File.Exists(input))File.Delete(input);if(File.Exists(result))File.Delete(result);}
        }catch(Exception ex){status.Text="Setup incomplete: "+ex.Message;}
        finally {busy=false;actions.IsEnabled=next.IsEnabled=true;}
    }
    internal void Preview(string file) {
        Show();UpdateLayout();var bitmap=new RenderTargetBitmap((int)ActualWidth,(int)ActualHeight,96,96,PixelFormats.Pbgra32);bitmap.Render(this);var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(bitmap));using(var output=File.Create(file))encoder.Save(output);Close();
    }
    internal static int Operation(string action,string input,string output) {
        try {
            if(!new[]{"Check","Prepare","Enroll","Poll","InstallPortal","InstallComponents","InstallGateway","InstallRuntime","ConfigureLan","CheckConnectivity","Status"}.Contains(action))throw new Exception("Unsupported setup action.");
            var ps=new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),"WindowsPowerShell","v1.0","powershell.exe")){UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true};
            foreach(var arg in new[]{"-NoProfile","-ExecutionPolicy","Bypass","-File",Path.Combine(PackageRoot(),"scripts","Setup-EpicVMFreshHost.ps1"),"-Action",action,"-InputFile",input,"-PackageRoot",PackageRoot()})ps.ArgumentList.Add(arg);
            using var process=Process.Start(ps)??throw new Exception("Could not run setup broker.");
            var text=process.StandardOutput.ReadToEndAsync();var errors=process.StandardError.ReadToEndAsync();process.WaitForExit();
            File.WriteAllText(output,text.GetAwaiter().GetResult()+errors.GetAwaiter().GetResult());return process.ExitCode;
        }catch(Exception ex){File.WriteAllText(output,ex.Message);return 1;}
    }
}
