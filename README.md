# RK Motorsport – Reservedele PWA

Mekanikere/hjælpere registrerer reservedele pr. kører under en løbsweekend. Bagefter laver admin en samlet liste pr. kører, som danner grundlag for fakturaen.

## Filer
| Fil | Indhold |
|---|---|
| `index.html` | Hele appen (React 18 + Babel standalone + supabase-js, ingen build) |
| `schema.sql` | Database, RLS-regler, godkendelsesfunktioner og triggere til Supabase |
| `supabase/functions/economic-send/` | Edge Function der opretter fakturakladder i e-conomic |
| `manifest.webmanifest`, `sw.js`, `icons/`, `logo.png` | PWA (installérbar, app-skal virker offline) |

## Opsætning
1. Opret et nyt projekt på supabase.com.
2. **SQL Editor** → indsæt hele `schema.sql` → Run.
3. **Authentication → URL Configuration**: sæt *Site URL* til appens adresse (fx `https://dele.rk-motorsport.dk`).
4. Kopiér *Project URL* og *anon public key* (Settings → API) ind øverst i `index.html`.
5. Læg mappen på hosting med HTTPS (GitHub Pages, Vercel, Netlify …).
6. **Den første bruger der opretter sig bliver automatisk admin**, så opret teamchefen først.

## Sådan bruges den
**Admin (teamchef)**
- *Løb*: opret weekenden (fx “DM afd. 3”). Luk løbet når weekenden er slut, så der ikke kan registreres mere.
- *Brugere*: mekanikere opretter selv en bruger i appen → godkend dem her (Afventer → Mekaniker).
- *Kørere*: opret kørere med nr., klasse og faktura-oplysninger, og sæt flueben ved de 1–2 personer der står for køreren.
- *Oversigt*: vælg løbet → liste pr. kører med totaler. Priser kan rettes direkte i listen. “Saml ens varer” lægger ens linjer sammen. Eksport til CSV (åbner i Excel med danske kommaer) eller Print/PDF med én kører pr. side. Markér som faktureret, når fakturaen er sendt.
- *Varer*: valgfri vareliste med stregkode, varenr. og pris. Import ved at kopiere kolonner direkte fra Excel: `stregkode;varenr;navn;pris`.

**Mekaniker**
- Ser kun sine egne kørere. Vælg kører → skriv hvad der er taget, antal, og eventuelt pris og note → Registrér.
- Kan slette egne linjer, så længe løbet er åbent og linjen ikke er faktureret.
- Uden netværk i depotet gemmes registreringen lokalt og synkroniseres automatisk, når der er forbindelse igen.

## Godkendelse og e-conomic
Flow efter hver løbsweekend:
1. **Teamchefen lukker løbet** (Oversigt → “Luk løb”). Herefter kan der ikke registreres mere.
2. **Den ansvarlige mekaniker godkender** sine køreres forbrug. Appen viser en påmindelse øverst, og listen låses ved godkendelse. Den ansvarlige vælges pr. kører under *Kørere* (★ Ansvarlig). Er ingen valgt, kan alle tilknyttede mekanikere godkende.
3. **Teamchefen godkender** under *Oversigt*, enten én ad gangen eller “Godkend alle”. Linjer uden pris skal prissættes først. Med “Send retur” går listen tilbage til mekanikeren med en besked.
4. **Send til e-conomic** opretter én **fakturakladde** pr. kører på kørerens kundenummer. Kladden bogføres og sendes fra e-conomic som normalt. Kladdenummeret vises i appen, og linjerne markeres som faktureret.

### Opsætning af e-conomic
1. Opret en gratis udvikleraftale på e-conomic.com/developer, opret en app med rollen *SuperUser* og gem **AppSecretToken**. Kræver CVR-nummer.
2. Åbn appens *Installation URL* logget ind i teamets e-conomic. Det giver en **AgreementGrantToken**.
3. Deploy funktionen og sæt nøglerne som secrets (kræver Supabase CLI):
   ```
   supabase functions deploy economic-send
   supabase secrets set ECONOMIC_APP_SECRET=xxx ECONOMIC_GRANT_TOKEN=yyy
   ```
4. I appen under *e-conomic*: angiv standard-varenummer (fx en vare “Reservedele” i e-conomic) og evt. standard-layout. Tryk “Test forbindelse”.
5. Giv hver kører et **e-conomic kundenummer** under *Kørere*. Kunden skal findes i e-conomic. Betalingsbetingelser, momszone og layout hentes fra kunden.
6. Priser i appen er inkl. moms og sendes som ekskl. 25 % moms. Det kan slås fra i indstillingerne. Varer i varelisten kan have deres eget e-conomic varenummer, ellers bruges standard-varenummeret. Linjeteksten er altid den tekst, mekanikeren har skrevet.

Opdatering af en eksisterende database: kør hele `schema.sql` igen. Data bevares.

## Stregkoder (forberedt)
- Stregkodefeltet virker allerede: findes koden i varelisten, udfyldes navn og pris automatisk.
- **USB-/Bluetooth-scannere** fungerer som tastatur og virker med det samme.
- **Kamera-scanning** (📷-knappen) vises kun i browsere med `BarcodeDetector`, dvs. Chrome på Android. Hvis det også skal virke på iPhone, kan `CameraScanner` skiftes til et bibliotek som `html5-qrcode` eller `@zxing/browser`.
- Man kan også skrive varenavnet i stedet. Feltet foreslår så varer fra listen.

## Sikkerhed (RLS)
- Mekanikere kan kun se og registrere på kørere, de er tilknyttet, og kun på åbne løb.
- Kun admin kan markere linjer som faktureret, ændre roller, kørere, løb og vareliste. En trigger håndhæver det også på databaseniveau.
- Godkendelser sker kun via databasefunktioner, der tjekker rolle og status. Efter teamchefens godkendelse er listen låst for alle.
- e-conomic-nøglerne ligger kun som secrets i Edge Function og aldrig i appen.
- Nye brugere har status “Afventer” og har ingen adgang, før de bliver godkendt.
