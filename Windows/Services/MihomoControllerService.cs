using System.IO;
using System.IO.Pipes;
using System.Net.Http;
using System.Text.Json;

namespace ProxyGauge.Services;

public sealed class MihomoControllerService
{
    private static readonly string[] KnownPipeNames = ["mihomo", "verge-mihomo"];

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
                    Timeout = TimeSpan.FromSeconds(2)
                };
                var json = await client.GetStringAsync(path, cancellationToken);
                return JsonDocument.Parse(json);
            }
            catch (Exception exception) when (exception is IOException or HttpRequestException or
                                               TaskCanceledException or UnauthorizedAccessException or
                                               JsonException)
            {
                // Try the next known local controller pipe. Raw controller data is never logged.
            }
        }

        return null;
    }
}
