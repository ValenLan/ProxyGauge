using System.IO;
using System.Reflection;

namespace CloudCheck.Services;

public sealed class RulePackService
{
    private const string ResourceName = "CloudCheck.Rules.CloudCheck-Merge.yaml";

    public string Version => "2026.08";

    public string Read()
    {
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(ResourceName)
            ?? throw new InvalidOperationException("找不到内置规则包。");
        using var reader = new StreamReader(stream);
        return reader.ReadToEnd();
    }

    public void Export(string path) => File.WriteAllText(path, Read());
}
