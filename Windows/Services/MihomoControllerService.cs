using System.IO;
using System.IO.Pipes;
using System.Net.Http;
using System.Text.Json;

namespace ProxyGauge.Services;

public sealed class MihomoControllerService
{
    private static readonly string[] KnownPipeNames = ["mihomo", "verge-mihomo"];
    private const int MaximumControllerResponseBytes = 4 * 1024 * 1024;

    public async Task<JsonDocument?> TryGetJsonAsync(
        string path,
        CancellationToken cancellationToken = default)
    {
        foreach (var pipeName in KnownPipeNames)
        {
            try
            {
                using var handler = new SocketsHttpHandler
                {
                    AllowAutoRedirect = false,
                    ConnectCallback = async (_, token) =>
                    {
                        var pipe = new NamedPipeClientStream(
                            ".",
                            pipeName,
                            PipeDirection.InOut,
                            PipeOptions.Asynchronous);
                        try
                        {
                            await pipe.ConnectAsync(650, token);
                            return pipe;
                        }
                        catch
                        {
                            await pipe.DisposeAsync();
                            throw;
                        }
                    }
                };
                using var client = new HttpClient(handler)
                {
                    BaseAddress = new Uri("http://localhost"),
                    Timeout = Timeout.InfiniteTimeSpan
                };
                return await GetJsonWithClientAsync(
                    client,
                    path,
                    TimeSpan.FromSeconds(2),
                    cancellationToken);
            }
            catch (Exception exception) when (
                !cancellationToken.IsCancellationRequested &&
                exception is IOException or HttpRequestException or OperationCanceledException or
                    UnauthorizedAccessException or JsonException)
            {
                // Try the next known local controller pipe. Raw controller data is never logged.
            }
        }

        return null;
    }

    internal static async Task<JsonDocument> GetJsonWithClientAsync(
        HttpClient client,
        string path,
        TimeSpan requestTimeout,
        CancellationToken cancellationToken = default)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(requestTimeout);
        var requestCancellation = deadline.Token;
        using var response = await client.GetAsync(
            path,
            HttpCompletionOption.ResponseHeadersRead,
            requestCancellation);
        response.EnsureSuccessStatusCode();
        if (response.Content.Headers.ContentLength is > MaximumControllerResponseBytes)
        {
            throw new HttpRequestException("Mihomo 控制端响应超出安全大小限制。");
        }

        await using var input = await response.Content.ReadAsStreamAsync(requestCancellation);
        using var output = new MemoryStream();
        var buffer = new byte[8192];
        while (true)
        {
            var read = await input.ReadAsync(buffer, requestCancellation);
            if (read == 0)
            {
                break;
            }
            if (output.Length + read > MaximumControllerResponseBytes)
            {
                throw new HttpRequestException("Mihomo 控制端响应超出安全大小限制。");
            }
            output.Write(buffer, 0, read);
        }
        return JsonDocument.Parse(output.ToArray());
    }
}
