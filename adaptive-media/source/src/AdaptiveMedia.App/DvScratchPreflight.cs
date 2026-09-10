using System.Globalization;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace AdaptiveMedia;

public interface IDvFreeSpaceProvider
{
    long GetAvailableBytes(string destinationDirectory);
}

public sealed class DvDriveFreeSpaceProvider : IDvFreeSpaceProvider
{
    public long GetAvailableBytes(string destinationDirectory)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(destinationDirectory);
        string directory = Path.GetFullPath(destinationDirectory);
        if (!OperatingSystem.IsWindows())
        {
            string? root = Path.GetPathRoot(directory);
            if (string.IsNullOrEmpty(root))
                throw new IOException($"Cannot resolve the destination volume for: {destinationDirectory}");
            return new DriveInfo(root).AvailableFreeSpace;
        }

        if (!GetDiskFreeSpaceEx(directory, out ulong available, out _, out _))
            throw new IOException($"Cannot query free space for destination directory: {directory}",
                new Win32Exception(Marshal.GetLastWin32Error()));
        return available > long.MaxValue ? long.MaxValue : (long)available;
    }

    [DllImport("kernel32.dll", EntryPoint = "GetDiskFreeSpaceExW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetDiskFreeSpaceEx(string directoryName, out ulong freeBytesAvailable,
        out ulong totalNumberOfBytes, out ulong totalNumberOfFreeBytes);
}

public sealed record DvScratchPreflight(
    long SourceBytes,
    long TemporaryArtifactsUpperBoundBytes,
    long OutputAllowanceBytes,
    long SafetyMarginBytes,
    long RequiredFreeBytes,
    long AvailableFreeBytes,
    bool Pass,
    string Reason)
{
    private const long MinimumOutputOverhead = 64L * 1024 * 1024;
    private const long MinimumSafetyMargin = 1024L * 1024 * 1024;

    public long PeakScratchUpperBoundBytes => SaturatingAdd(TemporaryArtifactsUpperBoundBytes, OutputAllowanceBytes);

    public static DvScratchPreflight Calculate(long sourceBytes, long availableFreeBytes)
    {
        if (sourceBytes <= 0) throw new ArgumentOutOfRangeException(nameof(sourceBytes));
        if (availableFreeBytes < 0) throw new ArgumentOutOfRangeException(nameof(availableFreeBytes));

        long temporary = SaturatingMultiply(sourceBytes, 2);
        long outputOverhead = Math.Max(MinimumOutputOverhead, CeilingDivide(sourceBytes, 100));
        long output = SaturatingAdd(sourceBytes, outputOverhead);
        long margin = Math.Max(MinimumSafetyMargin, CeilingDivide(sourceBytes, 20));
        long required = SaturatingAdd(SaturatingAdd(temporary, output), margin);
        bool pass = availableFreeBytes >= required;
        string reason = pass
            ? $"Scratch preflight passed: {Format(availableFreeBytes)} bytes available; {Format(required)} required."
            : $"Scratch preflight failed: {Format(availableFreeBytes)} bytes available; {Format(required)} required " +
              $"({Format(temporary)} temporary artifacts + {Format(output)} output allowance + {Format(margin)} safety margin).";
        return new(sourceBytes, temporary, output, margin, required, availableFreeBytes, pass, reason);
    }

    private static long CeilingDivide(long value, long divisor) => value / divisor + (value % divisor == 0 ? 0 : 1);

    private static long SaturatingMultiply(long value, long multiplier) =>
        value > long.MaxValue / multiplier ? long.MaxValue : value * multiplier;

    private static long SaturatingAdd(long left, long right) =>
        left > long.MaxValue - right ? long.MaxValue : left + right;

    private static string Format(long value) => value.ToString("N0", CultureInfo.InvariantCulture);
}

public sealed class DvScratchSpaceException(DvScratchPreflight report) : IOException(report.Reason)
{
    public DvScratchPreflight Report { get; } = report;
}
