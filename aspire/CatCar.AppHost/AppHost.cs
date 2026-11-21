using System.Security.Cryptography;

var builder = DistributedApplication.CreateBuilder(args);

var postgres = builder.AddPostgres("postgres").WithDataVolume();
var osDb = postgres.AddDatabase("catcar", "catcar_os");
var billingDb = postgres.AddDatabase("billing", "catcar_billing");
var executionDb = postgres.AddDatabase("execution", "catcar_execution");
var messaging = builder.AddRabbitMQ("messaging").WithManagementPlugin();
var mailpit = builder.AddContainer("mailpit", "axllent/mailpit", "v1.34.0")
    .WithHttpEndpoint(targetPort: 8025, name: "http");
var authStorage = builder.AddAzureStorage("auth-storage").RunAsEmulator();

var jwtSecret = builder.AddParameter("jwt-secret", Convert.ToBase64String(RandomNumberGenerator.GetBytes(32)), secret: true);
var customerJwtKey = builder.AddParameter("customer-jwt-signing-key", Convert.ToBase64String(RandomNumberGenerator.GetBytes(32)), secret: true);
var internalApiKey = builder.AddParameter("internal-api-key", Convert.ToBase64String(RandomNumberGenerator.GetBytes(32)), secret: true);
// Mercado Pago credentials are optional locally: a parameter is only wired when
// Parameters:<name> is configured (user-secrets or environment); otherwise the payment step fails fast.
IResourceBuilder<ParameterResource>? OptionalParameter(string name, bool secret = false) =>
    string.IsNullOrWhiteSpace(builder.Configuration[$"Parameters:{name}"]) ? null : builder.AddParameter(name, secret: secret);
var mercadoPagoToken = OptionalParameter("mercadopago-access-token", secret: true);
var mercadoPagoWebhook = OptionalParameter("mercadopago-webhook-secret", secret: true);
var mercadoPagoNotificationUrl = OptionalParameter("mercadopago-notification-url");

var execution = builder.AddDotnetProject("execution-service", "../../catcar-execution-service/src/Api/CatCar.Execution.Api.csproj")
    .WithHttpEndpoint(name: "http")
    .WithHttpHealthCheck("/health/ready")
    .WithEnvironment("ASPNETCORE_ENVIRONMENT", "Development")
    .WithReference(executionDb)
    .WithReference(messaging)
    .WithEnvironment("Jwt__Secret", jwtSecret)
    .WaitFor(executionDb)
    .WaitFor(messaging);

var billing = builder.AddDotnetProject("billing-service", "../../catcar-billing-service/src/Api/CatCar.Billing.Api.csproj");
billing
    .WithHttpEndpoint(name: "http")
    .WithHttpHealthCheck("/health/ready")
    .WithEnvironment("ASPNETCORE_ENVIRONMENT", "Development")
    .WithReference(billingDb)
    .WithReference(messaging)
    .WithEnvironment("Jwt__Secret", jwtSecret)
    .WithEnvironment("Communication__EmailTransport", "Mailpit")
    .WithEnvironment("Communication__MailpitBaseUrl", mailpit.GetEndpoint("http"))
    .WithEnvironment("Communication__SenderAddress", "noreply@catcar.local")
    .WithEnvironment("Communication__ExternalBaseUrl", billing.GetEndpoint("http"))
    .WaitFor(billingDb)
    .WaitFor(messaging)
    .WaitFor(mailpit);
if (mercadoPagoToken is not null)
{
    billing.WithEnvironment("Payments__Provider", "MercadoPago").WithEnvironment("MercadoPago__AccessToken", mercadoPagoToken);
    if (mercadoPagoWebhook is not null) billing.WithEnvironment("MercadoPago__WebhookSecret", mercadoPagoWebhook);
    if (mercadoPagoNotificationUrl is not null) billing.WithEnvironment("MercadoPago__NotificationUrl", mercadoPagoNotificationUrl);
}
else
{
    // No Mercado Pago credential configured: run the labelled payment SIMULATOR (no money moves; provider=simulator, SIM- references).
    // Configure Parameters:mercadopago-access-token to use the real Mercado Pago adapter instead.
    billing.WithEnvironment("Payments__Provider", "Simulator")
        .WithEnvironment("Payments__Simulator__BaseUrl", billing.GetEndpoint("http"));
}

var osService = builder.AddDotnetProject("os-service", "../../catcar-os-service/src/Api/CatCar.Api.csproj")
    .WithHttpEndpoint(name: "http")
    .WithHttpHealthCheck("/health/ready")
    .WithEnvironment("ASPNETCORE_ENVIRONMENT", "Development")
    .WithReference(osDb)
    .WithReference(messaging)
    .WithReference(execution)
    .WithEnvironment("Services__Execution", "https+http://execution-service")
    .WithEnvironment("Jwt__Secret", jwtSecret)
    .WithEnvironment("CustomerJwt__SigningKey", customerJwtKey)
    .WithEnvironment("InternalApi__Key", internalApiKey)
    .WaitFor(osDb)
    .WaitFor(messaging)
    .WaitFor(execution);

var authFunctionProjectPath = Path.GetFullPath(
    "../../catcar-auth-function/src/CatCar.AuthFunction/CatCar.AuthFunction.csproj",
    builder.Environment.ContentRootPath);

// Core Tools supplies the Functions host when an IDE launches the AppHost.
builder.AddExecutable("auth-function", "func", Path.GetDirectoryName(authFunctionProjectPath)!,
        "host", "start", "--port", "7071")
    .WithHttpEndpoint(port: 7071, name: "http", isProxied: false)
    .WithExternalHttpEndpoints()
    .WithUrlForEndpoint("http", url => { url.Url = "/api/auth/customer"; url.DisplayText = "Customer token page"; })
    .WithEnvironment("AzureWebJobsStorage", authStorage.AddBlobs("auth-host-blobs"))
    .WithEnvironment("AzureWebJobsDisableHomepage", "true")
    .WithEnvironment("OsService__BaseUrl", osService.GetEndpoint("http"))
    .WithEnvironment("OsService__InternalApiKey", internalApiKey)
    .WithEnvironment("FUNCTIONS_WORKER_RUNTIME", "dotnet-isolated")
    .WithEnvironment("FUNCTIONS_EXTENSION_VERSION", "~4")
    .WithEnvironment("AZURE_FUNCTIONS_ENVIRONMENT", "Development")
    .WithEnvironment("DOTNET_ENVIRONMENT", "Development")
    .WithEnvironment("CustomerJwt__SigningKey", customerJwtKey)
    .WithEnvironment("CustomerJwt__Issuer", "CatCar")
    .WithEnvironment("CustomerJwt__Audience", "CatCar.Api")
    .WithEnvironment("CustomerJwt__ExpirationMinutes", "60")
    .WithEnvironment("CustomerJwt__CorsOrigin", "http://localhost:7071")
    .WaitFor(osService)
    .WaitFor(authStorage);

builder.Build().Run();
