using System;
using System.IO;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;

namespace EpicVM.Desktop;

sealed partial class AgentWindow
{
    internal int CheckReleases() {
        int count=0;string root=Path.Combine(Path.GetTempPath(),"epicvm-release-check-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(root);
        void Check(bool value,string label){if(!value)throw new Exception(label);count++;}
        string Package(string name,string path,string hash) {
            string zip=Path.Combine(root,name+".zip");using var archive=ZipFile.Open(zip,ZipArchiveMode.Create);
            using(var writer=new StreamWriter(archive.CreateEntry(path).Open()))writer.Write("candidate");
            var manifest=new JsonObject{["schema"]=1,["product"]="EpicVM Host",["version"]="0.1.0",["files"]=new JsonArray(new JsonObject{["path"]=path,["sha256"]=hash})};
            using(var writer=new StreamWriter(archive.CreateEntry("release.json").Open()))writer.Write(manifest.ToJsonString());return zip;
        }
        try {
            var hash=Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes("candidate")));
            foreach(var path in new[]{"ui/EpicVM.Agent.dll","control/EpicVM.Control.dll","scripts/host_runtime.py"}) {
                var info=InspectPackage(Package("good-"+count,path,hash));
                Check(info.Version=="0.1.0","Manifest version read");
                Check(info.Impact==(path.StartsWith("ui/")?"agent-only":path.StartsWith("control/")?"control-restart":"desktops-must-end"),"Impact notice matches package scope");
            }
            foreach(var path in new[]{"ui/../escape.dll","host-runtime/signing.key","scripts/arbitrary.ps1"}) {
                bool refused=false;try{InspectPackage(Package("unsafe-"+count,path,hash));}catch(InvalidOperationException){refused=true;}Check(refused,"Unsafe manifest destination rejected");
            }
            bool corrupt=false;try{InspectPackage(Package("corrupt","ui/EpicVM.Agent.dll",new string('0',64)));}catch(InvalidOperationException){corrupt=true;}Check(corrupt,"Corrupt package cannot reach elevation");
            return count;
        }finally{Directory.Delete(root,true);}
    }
}
