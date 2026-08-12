# Identity Service — `docker-compose.yml` Config ব্যাখ্যা

এই ডকুমেন্টে `identity` সার্ভিসের নিচের ব্লকটার প্রতিটা লাইন ব্যাখ্যা করা হয়েছে:

```yaml
identity:
  build:
    context: ../kart-identity-service
  container_name: kart-identity
  ports:
    - "${IDENTITY_PORT}:8080"
  environment:
    ASPNETCORE_ENVIRONMENT: Development
    GlobalConfig__Path: /app/globalconfig.json
    Observability__Otlp__Endpoint: http://otel-collector:4317
  volumes:
    - ${GLOBALCONFIG_PATH}:/app/globalconfig.json:ro
    - ../kart-internals/logs/identity:/var/log/kart/kart-identity-service
  depends_on:
    postgres: { condition: service_healthy }
    redis: { condition: service_healthy }
    rabbitmq: { condition: service_healthy }
```

(নোট: `${GLOBALCONFIG_PATH}` একটা env var — এর আসল value কোথাও এই repo-তে লেখা নেই, দেখুন ৩ নম্বর পয়েন্ট।)

(পুরো ফাইল: [docker-compose.yml](../docker-compose.yml))

---

## ১) `${IDENTITY_PORT}` এর value কোথা থেকে আসে?

[`ports.env`](../ports.env)-এ define করা:

```
IDENTITY_PORT=8081
```

এই ফাইলটাই এই পুরো stack-এর **সব host port-এর single source of truth** — গিটে committed (secret নয়), কারণ নাম `.env` না হয়ে `ports.env` — এই ইচ্ছাকৃত নামকরণের কারণেই `.gitignore`-এর ব্ল্যাঙ্কেট `.env*` rule-টা এটাকে বাদ দেয় না।

`docker-compose.yml` নিজে থেকে এই ফাইল লোড করে না — এটা `docker compose --env-file ports.env ...` ফ্ল্যাগ দিয়ে পাস করতে হয়। [`scripts/dev-up.sh`](../scripts/dev-up.sh), [`dev-down.sh`](../scripts/dev-down.sh), [`dev-logs.sh`](../scripts/dev-logs.sh) স্ক্রিপ্টগুলো এটা ভেতরে ভেতরে already করে (`source ports.env` + `docker compose --env-file ports.env`)। সরাসরি `docker compose ...` চালালে এই ফ্ল্যাগ নিজে দিতে হবে, নাহলে `${IDENTITY_PORT}` resolve হবে না।

**চেক করার উপায়:**
```bash
cat ports.env | grep IDENTITY_PORT
# resolved মান দেখতে:
docker compose --env-file ports.env config | grep -A2 "container_name: kart-identity"
```

---

## ২) `GlobalConfig__Path`-এ `__` (double underscore) কী করে?

এটা .NET/ASP.NET Core-এর একটা **convention**। Environment variable-এর নামে `:` (colon) রাখা যায় না (shell-এ কলন allowed না), কিন্তু .NET-এর hierarchical configuration key গুলো `Section:Key` ফরম্যাটে থাকে। তাই .NET-এর `EnvironmentVariablesConfigurationProvider`-এর নিয়ম: env var-এর নামে দুইটা underscore (`__`) দেখলে সেটাকে `:` হিসেবে ধরবে।

তাই:
```
GlobalConfig__Path: /app/globalconfig.json
```
কোডের ভেতরে গিয়ে হয়ে যায়:
```
configuration["GlobalConfig:Path"] == "/app/globalconfig.json"
```

এই `GlobalConfig:Path` key-টা পড়ে [`GlobalConfigExtensions.cs`](../../kart-shared/src/Kart.Shared.Configuration/GlobalConfigExtensions.cs) (default key নামটা সেট করা আছে [`KartGlobalConfigOptions.cs`](../../kart-shared/src/Kart.Shared.Configuration/KartGlobalConfigOptions.cs)-এ `"GlobalConfig:Path"` হিসেবে), তারপর ওই path-এর ফাইলটা layer করে load করে।

---

## ৩) `/app/globalconfig.json` কে বানায়, কে দেয়? — আর `${GLOBALCONFIG_PATH}` কী?

Container-এর ভেতরে `/app/globalconfig.json` নামের ফাইলটা identity service নিজে বানায় না — এটা আসে **volume mount** থেকে (নিচের ৪ নম্বরে বিস্তারিত)। হোস্টে actual ফাইলটা **কোথায় থাকবে সেটা এই repo-র কোনো ফাইলেই লেখা নেই** — সেটা ইচ্ছাকৃতভাবে একটা env var-এর ভেতরে রাখা, যাতে repo দেখে কেউ বুঝতে না পারে real secret ফাইলটা ঠিক কোথায় বসানো আছে:

- `docker-compose.yml`-এর volume লাইনে literal path নেই, আছে `${GLOBALCONFIG_PATH}` — একটা variable
- এই variable-এর value আসে [`globalconfig.local.env`](../globalconfig.local.env) থেকে — এই ফাইলটা **gitignored**, শুধু এক লাইন: `GLOBALCONFIG_PATH=/আপনার/আসল/path/globalconfig.json`
- committed template আছে শুধু এই env ফাইলের জন্য: [`globalconfig.local.env.example`](../globalconfig.local.env.example) — এতে path নেই, শুধু placeholder
- আসল JSON ফাইলটা কী shape-এ লিখতে হবে তার জন্য আলাদা একটা committed reference আছে: [`compose/globalconfig/global.json.example`](../compose/globalconfig/global.json.example) — এটা কপি করে **যেকোনো জায়গায়** রাখতে পারেন (repo-র ভেতরে বা বাইরে, যেখানে খুশি), তারপর তার ভেতরের `Jwt.SigningKey.PrivateKeyPem` আর `Mfa.Encryption.KeyBase64` placeholder পূরণ করে সেই ফাইলের path-টা `globalconfig.local.env`-এ লিখে দিন
- `scripts/dev-up.sh` চালানোর সময় `globalconfig.local.env` না থাকলে, বা `GLOBALCONFIG_PATH` কোনো real ফাইলে point না করলে — সাথে সাথে error দিয়ে বন্ধ হয়ে যায় (fail fast); কোনো auto-generate হয় না, valid path নিজেই দিতে হবে, নাহলে identity সহ প্রতিটা container `GlobalConfig:Path` resolve করতে না পেরে বুট হতেই রিফিউজ করবে

---

## ৪) volumes mapping-টা কী করছে

```yaml
volumes:
  - ${GLOBALCONFIG_PATH}:/app/globalconfig.json:ro
  - ../kart-internals/logs/identity:/var/log/kart/kart-identity-service
```

Docker volume mapping ফরম্যাট: `<host-path>:<container-path>[:mode]`

- বাম পাশে **host মেশিনের** path
- ডান পাশে **container-এর ভেতরের** path
- `:ro` = read-only (container ফাইলটা edit করতে পারবে না, শুধু পড়তে পারবে)

লাইন ১: বাম পাশে literal path নেই, `${GLOBALCONFIG_PATH}` — একটা env var। `docker compose` চালানোর সময় এই variable resolve হয় [`globalconfig.local.env`](../globalconfig.local.env) থেকে (৩ নম্বরে বিস্তারিত), তারপর সেই resolved path-এর ফাইলটাকে container-এর ভেতরে `/app/globalconfig.json` নামে বসিয়ে দেওয়া হয় (read-only)। উপরের `GlobalConfig__Path` env var container-কে বলে দেয় ঠিক এই path-টাতেই খুঁজতে হবে — দুটো মিলেই কাজ করে।

লাইন ২: হোস্টের log ফোল্ডারকে container-এর `/var/log/kart/kart-identity-service` path-এ mount করছে, যেখানে Serilog file sink log লেখে। এখানে `:ro` নেই কারণ container-কে **write** করতে হয়।

---

## ৫) `kart-internals/globalconfig.json` কেন লাগে?

এটা ডুপ্লিকেট নয় — সম্পূর্ণ **আলাদা use-case**:

| | Docker (`docker-compose.yml`) | Bare-metal (`dotnet run`) |
|---|---|---|
| Config ফাইল | [`compose/globalconfig/global.json`](../compose/globalconfig/global.json) | `kart-internals/globalconfig.json` |
| Path কে বলে দেয় | env var `GlobalConfig__Path` | `appsettings.Local.json`-এর `GlobalConfig:Path` |
| Postgres host | `postgres` (Docker network name), port 5432 | `localhost`, port 5433 |
| Redis/Mongo | `redis:6379`, `mongo:27017` | `localhost:6380`, `localhost:27018` |

Docker-এ পুরো stack চালালে `global.json` লাগে। কিন্তু identity service সরাসরি IDE থেকে `dotnet run` করলে (container না বানিয়ে), সেই process localhost-এ থাকা infra ব্যবহার করে (ports.env-এর shifted পোর্টে exposed — 5433, 27018, 6380); container hostname (`postgres`, `redis`) সেখানে resolve হবে না।

এইজন্য [`kart-identity-service/src/Api/appsettings.Local.json`](../../kart-identity-service/src/Api/appsettings.Local.json) (gitignored, per-developer, [`.example`](../../kart-identity-service/src/Api/appsettings.Local.json.example) থেকে কপি করা) এ লেখা:
```json
{
  "GlobalConfig": {
    "Path": "/home/kakon/Developer/Personal/kart-commerce/kart-internals/globalconfig.json"
  }
}
```

⚠️ **গুরুত্বপূর্ণ:** দুই ফাইলের ভেতরের secrets (JWT signing key, MFA key ইত্যাদি) **আলাদা** — Docker-এ signup/MFA enroll করা user bare-metal সেটআপে কাজ করবে না, এবং vice versa।

---

## ৬) Identity-র log `kart-internals/logs`-এ দেখতে চাইলে

বর্তমানে Docker আর bare-metal-এর log path আলাদা রাখা **ইচ্ছাকৃত ডিজাইন** — `compose/globalconfig/logs/identity`, কারণ `kart-internals/logs` bare-metal রানের জন্য reserved (`kart-internals/globalconfig.json`-এর `Global.LogRoot` ওখানে পয়েন্ট করে)। দুইটা মিশিয়ে ফেললে Docker আর bare-metal একসাথে চললে log ফাইল conflict/overwrite হতে পারে।

তবু চাইলে [`docker-compose.yml`](../docker-compose.yml)-এ শুধু host-side path বদলানো যায়:

```yaml
volumes:
  - ./compose/globalconfig/global.json:/app/globalconfig.json:ro
  - /home/kakon/Developer/Personal/kart-commerce/kart-internals/logs/identity-docker:/var/log/kart/kart-identity-service
```

(container-side path — `/var/log/kart/kart-identity-service` — same থাকতে হবে, এটা কোডে `Global:LogRoot` + service name থেকে compute হয়)।

সহজ বিকল্প — ফাইল path নিয়ে না ভেবেই container log দেখতে:
```bash
./scripts/dev-logs.sh identity
# বা সরাসরি
docker compose --env-file ports.env logs -f identity
```
