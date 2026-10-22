# WiFi Heatmap (iPhone)

Two versions live in this repo:

- **`ios/` – native iPhone app (main version).** Scans your rooms with LiDAR to build the floor plan, tracks where you are with ARKit while you walk, and runs a speed test at each spot (manually or automatically every few metres). See [Native app](#native-app) below.
- **Root folder – web app.** Runs in Safari, no install. You load a floor plan image and tap where you stand.

Both use the same `server.py` for pure Wi-Fi measurements.

## Native app

**Needs:** iOS 17+. Room scanning needs LiDAR (12 Pro or newer Pro/Pro Max). Any other iPhone (e.g. iPhone 14) uses a **floor plan image** instead: pick it from Photos, then align it with two taps (see below). Position tracking works on all of them.

### Build without a Mac
Every push to `main` that touches `ios/` makes GitHub Actions build the app on a Mac in the cloud (`.github/workflows/ios-build.yml`). Open the repo's **Actions** tab → latest run → download **WifiHeatmap-unsigned-ipa**. You can also start a build by hand with **Run workflow**.

### Install on the iPhone
The cloud build is unsigned. Sign and install it with your Apple ID using **Sideloadly** (Windows or Mac):
1. Install Sideloadly, plug the iPhone in with a cable, trust the computer.
2. Drag `WifiHeatmap-unsigned.ipa` into Sideloadly, enter your Apple ID, press Start.
3. On the iPhone: Settings → General → VPN & Device Management → trust your Apple ID. Also turn on Settings → Privacy & Security → Developer Mode.

With a free Apple ID the app must be re-installed every 7 days. A paid Apple Developer account ($99/year) gives 1-year installs and makes TestFlight possible.

With a Mac instead: `brew install xcodegen`, `cd ios && xcodegen generate`, open `WifiHeatmap.xcodeproj`, pick your team under Signing, run on the phone.

### Using it
1. **Scan a space with LiDAR** – walk slowly through every room, camera at the walls. Press *Done scanning*.
2. The plan appears with a blue dot for you. Walk to a spot, hold still, press **Measure here**. Or turn on **Auto**: every time you stop at a new spot (default 3 m from the last point) it measures by itself.
3. Switch **Down / Up / Ping** at the top. Tap a point for details or to delete it.
4. If the dot is in the wrong place, press **I'm here** and tap your real position.
5. **⋯** menu: share the heat map image, export JSON/CSV, measure by tapping the plan, settings.
6. **Floor plan image (no LiDAR):** *Survey on a floor plan image* → pick the image. Stand at a spot you can find on the plan (doorway, room corner) and tap it. Walk at least 3–4 m to another recognisable spot and tap it. The app works out scale, rotation and position from those two taps; then the blue dot follows you. *Re-align plan* in the ⋯ menu starts over.
7. Re-opening a survey later: walk around the scanned area with the camera up until it finds its position, then continue.

Settings → *Local server* takes the address `server.py` prints (e.g. `192.168.1.20:8080`).

## Web app

### Two ways to run it

#### 1. GitHub Pages (simplest)
1. Create a repository and upload all files in this folder.
2. In the repo go to **Settings → Pages**, set Source to **Deploy from a branch**, branch `main`, folder `/ (root)`.
3. Open `https://<your-username>.github.io/<repo>/` on the iPhone.
4. Tap **Share → Add to Home Screen**.

In this mode tests go to Cloudflare's speed test servers, so results include your internet connection. That is fine for finding weak spots, but if Wi-Fi is faster than your internet plan, the plan becomes the ceiling.

#### 2. Local server (pure Wi-Fi measurement)
1. On a computer **connected to the router by cable**, run:
   ```
   python3 server.py
   ```
2. It prints an address like `http://192.168.1.20:8080`. Open that on the iPhone.
3. The app detects the local server automatically ("Auto" in More → Test server).

Now every test measures only the phone ↔ router Wi-Fi link.

### How to survey
1. **Plan** – choose a floor plan image (a photo of a printed plan or a screenshot works), or use the blank grid.
2. **Scale** (optional, recommended) – tap both ends of a wall or door you know the length of, then enter metres (`4.5`) or feet (`15ft`).
3. **Start** – tap where you begin (e.g. next to the router).
4. **Measure** – stand at a spot, tap it on the plan, hold still about 8 seconds. Repeat every 3–5 m and in every room, including corners and the far ends.
5. Switch between **Down / Up / Ping** at the top. Tap a point to retest or delete it.
6. **More → Share heat map image** to save or send a PNG. **Save survey file** keeps everything (plan included) as a `.json` you can open later.

### Notes
- iOS does not allow web or regular apps to read Wi-Fi signal strength (dBm), so this measures real throughput and latency instead.
- A spot where the server cannot be reached at all is saved as a dead spot (red ✕).
- Colour thresholds are adjustable in **More → Colour scale**.
- Data is kept in Safari's storage on the phone. Export a survey file to keep a permanent copy.
