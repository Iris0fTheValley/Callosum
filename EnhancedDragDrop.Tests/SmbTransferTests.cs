using MouseWithoutBorders.EnhancedDragDrop;
using Xunit;

namespace EnhancedDragDrop.Tests;

public sealed class SmbFactAttribute : FactAttribute
{
    public SmbFactAttribute()
    {
        if (string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("MWB_SMB_SMOKE_SOURCE")) ||
            string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("MWB_SMB_SMOKE_TARGET")))
        {
            Skip = "Set MWB_SMB_SMOKE_SOURCE and MWB_SMB_SMOKE_TARGET to run the UNC integration test.";
        }
    }
}

public sealed class SmbTransferTests
{
    [SmbFact]
    public async Task Streaming_backend_copies_a_real_unc_source()
    {
        var source = Environment.GetEnvironmentVariable("MWB_SMB_SMOKE_SOURCE")!;
        var target = Environment.GetEnvironmentVariable("MWB_SMB_SMOKE_TARGET")!;
        var backend = new StreamingFileTransferBackend();
        var report = await backend.CopyAsync([source], target);
        Assert.Empty(report.Failures);
        Assert.Single(report.Copied);
        Assert.True(File.Exists(report.Copied[0]));
    }
}
