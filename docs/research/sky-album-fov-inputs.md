# Sky Album: FOV and pointing inputs per frame, and FITS backfill of old frames

Research for [#1497](https://github.com/open-astro/openastro-ara/issues/1497) (child of
[#1489](https://github.com/open-astro/openastro-ara/issues/1489)). Every claim below was checked against
the code at `f176a1ec6` (fork/master); `file:line` references are to that commit. Ticket claims
are marked **confirmed** or **corrected**.

## Question

Which data lets the daemon decide "catalog object X was inside frame F" using FOV containment on the
mount pointing read at capture?

## 1. Where the pointing is read, and in what frame

**Read site.** `CameraService.CaptureAsync` calls `ReadPointing()` once per frame, right after pixel
readout, next to the focuser and rotator snapshots (`OpenAstroAra.Server/Services/CameraService.cs:977-980`).
`ReadPointing` (`CameraService.cs:262-269`) calls `PointingFrom(_telescope?.Invoke()?.GetInfo())`, i.e. it
reads the telescope mediator's cached `TelescopeInfo`, not the mount live. The cache is the §32.4 refresh
(about every 2 s; comment at `CameraService.cs:256-259`), so with tracking on the value is the frame's
pointing to well under a pixel; with a slew started at readout it can be one refresh stale.

**Epoch.** `PointingFrom` (`CameraService.cs:233-258`) returns a `FramePointing(RaHours, DecDegrees, Epoch)`:

- `null` when no mount is connected or `info.Coordinates` is null (`:234-236`).
- `TelescopeService.Mediator.GetInfo` leaves `Coordinates` null until the mount's `EquatorialSystem` has been
  read (`OpenAstroAra.Server/Services/TelescopeService.Mediator.cs:120-126`, #1124), so a frame taken in the
  first seconds after connect can have no pointing even with a mount attached.
- Mount reports J2000: passed through as J2000 (`:238-240`).
- Mount reports JNOW (the common case, `MapEpoch` maps everything but J2000/J2050/B1950 to JNOW,
  `TelescopeService.Mediator.cs:213-218`): transformed to J2000 via `Coordinates.Transform` (`:249-251`).
  If the SOFA native library is missing the position is kept **in JNOW** and flagged with its epoch
  (`:252-256`), about 0.4 deg of precession today.
- B1950/J2050 mounts: kept in their own epoch, flagged (`:244-247`).

So at header-write time the numbers are J2000 in the normal case, and the epoch is always known from
`FramePointing.Epoch`. Test coverage: `OpenAstroAra.Test/CameraServicePointingHeaderTest.cs`,
`OpenAstroAra.Test/TelescopeEquatorialSystemUnknownTest.cs:150-157`.

**Header write.** The pointing travels in `FrameSaveJob.Pointing` (`CameraService.Saving.cs:48`) into
`WriteFrame` (`Saving.cs:120-123`, `CameraService.cs:1419`) and `WritePointingHeaders`
(`CameraService.cs:1662-1678`), which writes:

| Card | Value |
|---|---|
| `OBJCTRA` | `HH MM SS` (NINA sexagesimal) |
| `OBJCTDEC` | `+DD MM SS` |
| `RA`, `DEC` | decimal degrees, rounded to 6 places |
| `EQUINOX` | `2000.0` for J2000; `1950.0`/`2050.0` for B1950/J2050; the capture's Julian year for an untransformed JNOW (`:1670-1675`) |

The same cards are written to XISF frames (`OpenAstroAra.Test/FrameFileFormatTest.cs:51,140`).

**Never stored on the row: confirmed.** `RegisterFrameAsync` (`CameraService.cs:1925-1960`) builds the
`FrameDto` without any RA/Dec; `FrameDto` (`OpenAstroAra.Server/Contracts/ImageDtos.cs:43-93`) has no such
field; the `frames` DDL (`OpenAstroAra.Server/Services/SqliteAraDatabase.cs:84-110`) and the additive
columns (`:117-121`, `:152-159`) contain no pointing column. The pointing value is in hand in
`SaveFrameAsync` (`job.Pointing`) at the moment `RegisterFrameAsync` is called (`Saving.cs:127-129`), so
storing it is a new `FrameDto` field plus one `AddColumnIfMissingAsync` pair, nothing more.

## 2. Which fields give the frame's angular FOV

FOV (deg) per axis = `pixels x bin x pixel_size_um / (focal_mm x reducer) x 206.265 / 3600`
(the formula the repo already documents at `OpenAstroAra.Server/Contracts/ProfileDtos.cs:612-614`).

| Input | Where | Nullable / caveat |
|---|---|---|
| Image width/height in pixels | `frames.width`, `frames.height`, `INTEGER NOT NULL` (`SqliteAraDatabase.cs:97-98`); they are the downloaded image's dimensions, i.e. **binned** pixels (`CameraService.cs:777` returns the readout `Width/Height`, passed through `FrameSaveJob` to `RegisterFrameAsync`) | always present |
| Binning | `frames.bin` (`SqliteAraDatabase.cs:154`), set from the driver-reported binning `appliedBin ?? request.BinX` (`CameraService.cs:1952`) | **nullable**: rows older than #1140 P2, and every row inserted by the orphan scan (`CaptureScanService.cs` INSERT column list has no `bin`) |
| Focal length, reducer, pixel size | profile `OpticsSettingsDto.FocalLengthMm`, `ReducerFactor`, `PixelSizeUm` (`ProfileDtos.cs:626-634`); effective focal = `PlateSolveService.ResolveSolveGeometry` (`OpenAstroAra.Server/Services/PlateSolveService.cs:53-60`) | `0 = unset`; **not recorded per frame** anywhere in the DB: a profile edit or a scope swap rewrites history |
| Sky position angle | nothing. `frames.rotator_mechanical_deg` (`:158`) is the rotator's mechanical angle, not a sky PA, and is null without a rotator | missing |

The FITS header is a better per-frame record of the optics than the DB: `WriteStandardHeaders` writes
`FOCALLEN` (effective, reducer applied), `APTDIA`, `XPIXSZ`/`YPIXSZ` (**already multiplied by bin**)
when `prefs.HeaderOptics` is on (default `true`, `ProfileDtos.cs:223`) and the values are > 0
(`CameraService.cs:1570-1584`), plus `XBINNING` (`:1443`). So a frame's FOV can be computed from its own
header as `NAXIS1 x XPIXSZ / FOCALLEN`, independent of `bin` and of later profile edits. Frames taken with
the optics unset in the profile carry no `FOCALLEN`/`XPIXSZ` and have no computable FOV from any source.

**Containment math available today.** Server: `SiteAstrometry.AngularSeparationDeg` (great-circle,
`OpenAstroAra.Server/Services/SiteAstrometry.cs:105-111`). Client: gnomonic `tanToRaDec` and the frame
grid math in `client/openastroara_client/lib/util/mosaic_geometry.dart:56`. No rectangle-on-sphere test
exists in either; without a sky PA a rectangle test is not possible anyway. A rotation-independent rule
that needs only what exists: object is "in frame" when its separation from the pointing is at most half
the frame's **short** side (inscribed circle; conservative, so a card never lights up for an object that
was off the chip), and `sizeMajArcmin` can widen it for extended objects if wanted.

## 3. Backfilling existing frames

**Keywords present.** Every frame captured since #1091 (`73c2cfbf1`) with a mount connected carries
`OBJCTRA/OBJCTDEC/RA/DEC/EQUINOX` (section 1). Frames from before #1091, frames taken with no mount, and
frames from the first seconds after connect (#1124) lack them. NINA archives copied onto the drive carry
NINA's own `OBJCTRA/OBJCTDEC` (target, not mount) and `RA/DEC` in degrees
(`OpenAstroAra.Image/FileFormat/FITS/CFitsioFITS.cs:211-212,275`), so the same parser works on them.

**Parser exists.** `SqliteFrameRepository.ParseTargetCoordinates` (`OpenAstroAra.Server/Services/SqliteFrameRepository.cs:941-958`)
turns `OBJCTRA/OBJCTDEC` into (RA deg, Dec deg) with digit and range guards;
`TryReadTargetCoordinatesAsync` (`:908-932`) is a header-only read of one frame by id, deliberately
ignoring `EQUINOX` (its comment accepts the 0.4 deg JNOW case for a solve hint). The header reader is
`FrameFileReader.ReadHeaderInfo(path)` -> `(Width, Height, Headers)` (`OpenAstroAra.Server/Services/FrameFile.cs:449`),
FITS and XISF.

**`RebuildStatsCatalog` re-reads files: confirmed, but it is a wipe, not an update.**
`POST /api/v1/stats/rebuild-catalog` (`OpenAstroAra.Server/Endpoints/StatsEndpoints.cs:45-73`) calls
`CaptureScanService.ResetAndRescanAsync` (`OpenAstroAra.Server/Services/CaptureScanService.cs:91-123`), which runs
`DELETE FROM frames; DELETE FROM sessions;` in one transaction (`:102-109`) and then the orphan scan.
The scan's `TryRecoverAsync` (`:237` onward) does read every header via `ReadHeaderInfo` (`:245`) but
inserts a fresh row with a **new id**, a synthetic per-(target, night) recovery session, and only the
columns it parses: no `bin`, no `background_adu`, `rating = 0`, `tags = '[]'`, HFR only if the file has an
`HFR` card (`:262-280` and the INSERT at `:297-310`). It does not parse `OBJCTRA/OBJCTDEC` today. Riding
the backfill on this endpoint would cost users their ratings, tags, measured backgrounds, binning and real
session grouping, and would renumber every frame id the client has cached. The startup scan
(`Program.cs:1412-1427` -> `RunAsync`) is non-destructive but only touches files whose path is not already
in `frames` (`LoadKnownIdsAsync`, `:222-235`), so it never revisits catalogued rows either.

Conclusion: there is no existing non-destructive pass that re-reads headers of catalogued frames. The
backfill needs its own idempotent `UPDATE` pass: `SELECT id, file_path FROM frames WHERE ra_deg IS NULL`,
`ReadHeaderInfo`, `ParseTargetCoordinates`, write `ra_deg/dec_deg` (and mark rows whose file has no
cards so they are not re-opened every boot). `TryRecoverAsync` should also learn the two cards so a drive
rescan fills them for new rows.

## 4. Where the catalog lives

**Client.** `PlanningDso` (`client/openastroara_client/lib/services/dso_catalog_service.dart:16-45`) carries
`raDeg`, `decDeg`, `messierNum`, `caldwellNum`, `type`, `magnitude`, `sizeMajArcmin/sizeMinArcmin`,
`posAngleDeg` and `aliases`. The full set (~16k rows: OpenNGC, Sharpless, LDN, Barnard, vdB, Abell PN, Arp,
WR) is bundled as assets and parsed on-device (`client/openastroara_client/lib/services/bundled_catalogs.dart:19-42`;
Messier from the `M` column, Caldwell from `C NNN` identifiers, `:61-62,108,124`), exposed by
`bundledCatalogProvider` (`client/openastroara_client/lib/state/sky_atlas/dso_catalog_state.dart:48-49`) with no
server dependency. Alias merging is `mergeDuplicates` (`bundled_catalogs.dart:44-47`).

**Daemon.** `SkyCatalogService` (`OpenAstroAra.Server/Services/SkyCatalogService.cs`) parses the same column
layout and already knows `MessierNum`/`CaldwellNum` per row (`DsoRow`, `:83-86`; catalog defs `:101-102`),
**but only from Data Manager packages the user chose to download** (`DsoPackages` at `:62-65`, read from
`{skyDataRoot}/<pkg>/catalog.csv`, `:67-72`; `openngc-dso` is a downloadable package,
`OpenAstroAra.Server/Services/DataManagerService.cs:87-96`). `GetAllDsos` returns null and
`/api/v1/data-manager/dso-catalog` returns 404 until it is installed
(`OpenAstroAra.Server/Endpoints/SystemEndpoints.cs:228-240`). There is no bundled catalog in the daemon
binary. The stats layer is keyed purely by `target_name`
(`OpenAstroAra.Server/Services/SqliteStatsService.cs:47` `COUNT(DISTINCT target_name)`; `GetTargetsAsync`
`:110-117` `GROUP BY target_name`), as the ticket says.

## Recommendation

Split the work along the existing seam: the daemon owns per-frame facts, the client owns the catalog
and the planning math (the repo's "planning-compute-lives-in-client" rule, `ProfileDtos.cs:478-480`).

1. **Daemon, capture path.** Add nullable `frames.ra_deg`, `frames.dec_deg` (J2000) via
   `AddColumnIfMissingAsync` after the rebuild passes (same spot as `:152-159`), a `FrameDto` field, and
   pass `job.Pointing` into `RegisterFrameAsync`. Store the position only when `FramePointing.IsJ2000`,
   or store it regardless and accept the 0.4 deg JNOW error the solve-hint reader already accepts; the
   inscribed-circle rule tolerates it on fields wider than about 1 deg, not on long focal lengths. Storing
   only J2000 is the safer default. Also write the pair in `CaptureScanService.TryRecoverAsync`.
2. **Daemon, backfill.** One idempotent update pass over `frames WHERE ra_deg IS NULL` using
   `ReadHeaderInfo` + `ParseTargetCoordinates`, run once at startup after the orphan scan (same guard as
   `Program.cs:1420-1427`) and skipping rows already probed. Do not route it through
   `rebuild-catalog`: that endpoint deletes the catalog.
3. **FOV inputs.** Do not add focal length or pixel size to the row. Expose per-frame
   `ra_deg, dec_deg, width, height, bin` plus the frame facts the album needs (`captured_utc`,
   `exposure_seconds`, `filter_name`, best-frame score) in one light-frame listing, and let the client
   compute pixel scale from the active profile's optics it already holds
   (`client/openastroara_client/lib/state/settings/optics_settings_state.dart`). Known limit: a scope
   swap changes the FOV of old frames; if that matters later, store `pixel_scale_arcsec` at capture (the
   value is computed at `CameraService.cs:1570-1584` anyway).
4. **Matching on the client.** Containment = `AngularSeparationDeg(object, pointing) <= min(fovW, fovH)/2`
   against `bundledCatalogProvider`; frames with `ra_deg IS NULL` fall back to alias matching on
   `target_name` with `PlanningDso.aliases`. This avoids shipping a catalog to the daemon, keeps
   `openngc-dso` optional, and works offline like the rest of planning. Extending
   `GET /api/v1/stats/targets` to catalog-object keys would require the daemon to have the catalog, which
   it does not have on a default install.

## Ticket claims, verified

| Claim | Verdict |
|---|---|
| `CameraService.cs:980` calls `ReadPointing()` per frame | confirmed (`:980`) |
| Written to the FITS header at `:1552` | confirmed (`:1551-1552` -> `WritePointingHeaders :1662`) |
| Never saved to the `frames` row | confirmed (`RegisterFrameAsync :1925-1960`, DDL `:84-110`) |
| FOV from `width`/`height` + profile focal length and pixel size | confirmed, with `bin` nullable and no per-frame optics or PA |
| Old frames carry `RA/DEC` in headers | confirmed for frames since #1091 with a mount connected and a known equatorial system; not for older/no-mount frames |
| `RebuildStatsCatalog` already re-reads files | corrected: it wipes `frames` and `sessions` then re-ingests under new ids, losing ratings/tags/bin/background; not a backfill vehicle |
| Daemon has a catalog | corrected: only if the user installed `openngc-dso` through the Data Manager; nothing bundled |
