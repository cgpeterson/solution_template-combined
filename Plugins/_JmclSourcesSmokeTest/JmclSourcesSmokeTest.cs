// TEMPORARY VERIFICATION FILE -- not part of the template.
//
// Plugins.csproj is a legacy, non-SDK-style .csproj (required by spkl and the
// strong-naming setup). JMCL's own proof that contentFiles with
// buildAction="Compile" actually reaches the compiler under PackageReference
// (samples/SourcePackageSmokeTest in the JMCL repo) is an SDK-style project.
// That is a different NuGet/MSBuild code path, and contentFiles auto-wiring
// into the Compile item list is a documented weak spot specifically for
// legacy-style PackageReference projects: the files can land in the NuGet
// cache without ever becoming a <Compile> item, so the assembly would build
// "successfully" with these types silently missing.
//
// This file exists purely to force the question: if it references real types
// from JMCL.Dataverse.Sdk.Sources and JMCL.Core.IocContainer.Sources and the
// build fails with CS0246 (type or namespace not found), contentFiles is not
// wiring into this project format and the App_Packages/packages.config
// removal in this branch needs to be reverted. If it compiles clean, the
// mechanism is proven for this exact project shape.
//
// Delete this file and its ItemGroup entry in Plugins.csproj once verified.
namespace SolutionTemplate.JmclSourcesSmokeTest
{
    public class SmokeTestPlugin : JMCL.Dataverse.Sdk.CDSPlugin
    {
        public SmokeTestPlugin() : base(null, null) { }

        // Also proves JMCL.Core.IocContainer.Sources compiled in, since
        // CDSPlugin.Container is typed against JMCL.Core.IocContainer.IIocContainer.
        public JMCL.Core.IocContainer.IIocContainer Probe => Container;
    }
}
