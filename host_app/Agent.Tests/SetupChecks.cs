using System;
using System.Threading.Tasks;
using System.Windows;

namespace EpicVM.Desktop;

sealed partial class SetupWindow {
    internal async Task<int> CheckSetup() {
        int count=0;
        void Check(bool passed,string message){if(!passed)throw new Exception(message);count++;}
        Check(step==0&&configurationFields.Visibility==Visibility.Collapsed,"First step keeps the main setup action visible.");
        layout.SelectedIndex=1;
        Check(agent.Text=="http://100.64.0.1:8765"&&!password.IsEnabled,"Separate-server setup does not request a local portal password.");
        Check(Array.IndexOf(Journey,"InstallPortal")==-1&&Array.IndexOf(Journey,"ServerGuide")>=0,"Separate server uses its own installation journey.");
        layout.SelectedIndex=0;
        Check(password.IsEnabled&&Array.IndexOf(Journey,"InstallPortal")>=0,"Same-PC setup restores local portal preparation.");
        step=Array.IndexOf(Journey,"ConfigureLan");UpdateStep();
        Check(lanFields.Visibility==Visibility.Visible&&configurationFields.Visibility==Visibility.Collapsed,"Local setup has a dedicated optional step.");
        Check(dataRoot.Text.EndsWith("EpicVM")&&Journey[step-1]=="InstallRuntime","Storage defaults to protected data and LAN follows runtime.");
        step=0;UpdateStep();
        await Run("Check",true);
        Check(step==0&&status.Text.Contains("Missing: python/python.exe"),"Actual broker multiline JSON is read; an incomplete source package cannot advance setup.");
        return count;
    }
}
