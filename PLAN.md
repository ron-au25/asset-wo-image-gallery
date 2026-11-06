# Asset / Work Order Image Gallery — Plan

## Context
Techs and supervisors need a fast thumbnail view of every photo tied to an Asset (and its child assets) or a Work Order (and its child WOs and related records), without opening each record. It must work in desktop Lightning and in the Field Service mobile app (online only). It can be opened as a quick action, a record-page component, or from a work step through an LWC quick action, on both web and mobile.

**Hard constraint: no new custom fields or objects.** That includes custom metadata types and ContentVersion fields. Nothing is stored. All data is read live. (Exception, 2026-11-06: the two ContentVersion fields that already existed in the org, `Capture_Time__c` and `Geolocation__c`, are now kept in the project so a new org gets them; see the build log. No other field or object was added.)

Decisions made:
- Online only.
- Location = photo EXIF GPS read live. Later extended (see build log): optional ContentVersion fields when EXIF has none (green pin), and the Work Order address as a last fallback (red pin). "No location" only when none exist.
- Grid view with a timeline toggle.
- Full depth for Assets.
- Never show a record Id. Every record is shown by number, subject or name plus a relevant date.

## Facts checked in rsfieldnov25.demo
- **Images:** 1,022 image files. Average JPEG 23 KB, largest 4.9 MB.
- **Links today:** WorkOrder 65, WOLI 14, Measure_Point__c 11, RS_PurchaseOrder__c 2. Other objects have none, so we need seed data.
- **Custom children found by describe:**
  - Under WorkOrder: `Measure_Point__c`, `Work_Delay__c`, `Safety_Incident__c`, `Time_Report__c`, `RS_PurchaseOrder__c`.
  - Under Asset: `Measure_Point__c`, `SDO_SCOM_Replacement_Parts__c`.
- **ContentVersion** has no location field, so GPS has to come from the image bytes.
- **Reuse:** links are queried by `LinkedEntityId IN :ids` in `Workshop Kiosk/.../KioskBlocks.cls:496`.
- **Gotchas from memory:**
  - Return a JSON string, not DTO types.
  - Don't use `cacheable=true` for imperative calls.
  - `deploy -t` runs 0 tests.
  - WorkPlan OWD is Private, so collect WorkStep/WorkPlan IDs in system mode.
  - Re-query the org after deploy.

## Objects and display fields (existing fields only, all verified)
Each record is shown as **Object label · Title · Subtitle · Key date**, plus a breadcrumb (Asset name › WO number › record). Ids are used only internally for navigation.

| Object | Link to anchor | Title | Subtitle | Key date |
|---|---|---|---|---|
| Asset (+ child tree) | `RootAssetId` + `ParentId` (in memory) | `Name` | `SerialNumber`, `Status` | `InstallDate`, else `CreatedDate` |
| WorkOrder (+ child tree) | `RootWorkOrderId` + `ParentWorkOrderId` (in memory); `AssetId` | `WorkOrderNumber` | `Subject`, `Status` | `StartDate`, else `CreatedDate` |
| WorkOrderLineItem | `WorkOrderId`, `AssetId` | `LineItemNumber` | `Subject`, `Status` | `StartDate`, else `CreatedDate` |
| WorkPlan | `WorkOrderId` | `Name` | — | `CreatedDate` |
| WorkStep | `WorkOrderId` | `Name` | `Status` | `StartTime`, else `CreatedDate` |
| ServiceAppointment | `ParentRecordId` (WO + WOLI) | `AppointmentNumber` | `Subject`, `Status` | `ActualStartTime`, else `SchedStartTime`, else `CreatedDate` |
| Case | `AssetId`; WO `CaseId` | `CaseNumber` | `Subject`, `Status` | `CreatedDate` |
| Measure_Point__c | `Asset__c`, `Work_Order__c` | `Component_Name__c`, else `Name` | `Measure_Type__c`, `Measure_Value__c`, `Defect_Location__c` | `Update_Date__c`, else `CreatedDate` |
| Work_Delay__c | `Work_Order__c` | `Name__c`, else `Name` | `Delay_Reason__c` | `Start_Date__c`, else `CreatedDate` |
| Safety_Incident__c | `Work_Order__c` | `Subject__c`, else `Name` | `Injury_Type__c`, `Status__c` | `Incident_Date__c`, else `CreatedDate` |
| Time_Report__c | `Work_Order__c` | `Name` | `Resource_Name__c`, `Status__c` | `Start_Time__c`, else `CreatedDate` |
| RS_PurchaseOrder__c | `Work_Order__c` | `PO_Number__c`, else `Name` | `Supplier_Name__c`, `Status__c` | `Document_Date__c`, else `CreatedDate` |
| SDO_SCOM_Replacement_Parts__c | `Asset__c` | `Name` | `Product__r.Name` | `CreatedDate` |

This table lives in code as a static source list in `ImageGallerySources.cls`, not in CMDT. Each field is checked against describe at runtime and skipped if missing or not accessible, so a missing object doesn't break the component.

## Architecture

### EXIF strategy: client first, server fallback (decided by spike step 1)
- **Path A, preferred: client-side EXIF in the LWC.**
  - `fetch('/sfc/servlet.shepherd/version/download/<versionId>', {headers: {Range: 'bytes=0-65535'}})`, then `arrayBuffer()`, then a `DataView` parser in JS.
  - No Apex CPU or heap, no callouts, no API usage, no Named Credential, no integration user.
  - The request runs in the user's own session, so sharing is native.
  - It must use the **original file**. Renditions (`THUMB*`) are re-encoded and carry no EXIF.
  - **Unproven:** in Lightning, the servlet URL redirects from `*.lightning.force.com` to the `*.file.force.com` content domain. A cross-origin `fetch` needs CORS headers on the response, and the domain must be allowed by Lightning's CSP `connect-src`. `<img>` tags don't need either; `fetch` does. If either is missing, the fetch fails, and the spike must test this on web and in Field Service mobile.
  - If the content domain is blocked by CSP alone, a CSP Trusted Site for `*.file.force.com` (setup metadata, not a field or object) may fix it. Test that too.
- **Path B, fallback only if A fails: server-side EXIF** (`getExif`, below), with the Named Credential setup in section 4.
- If Path A works, **delete section 4 and `getExif`** before building.

### 1. Apex (no stored data; `with sharing`; user mode)
- **`ImageGallerySources`**: the static source definitions above.
- **`ImageGalleryController.getImages(Id recordId)` → String (JSON)**, `@AuraEnabled`, not cacheable.
  - Kept as a JSON string, not typed DTOs: memory note `lwc-apex-dto-marshalling`, where custom types came back with all fields null.
  1. Resolve the anchor from the record type:
     - Asset → Asset context; every WO found then gets the full WO context.
     - WorkOrder → WO context.
     - WorkStep, WOLI, SA → resolve to the parent WO, and highlight the launching record.
  2. **Flat tree fetch, not a level-by-level walk:**
     - One query: `Asset WHERE RootAssetId = :root` (or `WorkOrder WHERE RootWorkOrderId = :root`).
     - Build the `ParentId` map in memory and keep only the descendants of the anchor.
     - That's 1 query instead of up to 10. For an Asset with many WOs, it's one `RootWorkOrderId IN :roots` query.
  3. **Record budget:** 5,000 related records in total. Past that, set `truncated` with a reason.
  4. Run one query per source (about 15) and build `RecordRef{objectLabel, title, subtitle, dateLabel, dateValue, createdDate, breadcrumb[]}`.
     - SOQL total is about 2 + 15 + link chunks, so roughly 25 of the 100 allowed.
  5. Query `ContentDocumentLink` with `LinkedEntityId IN :ids` in **chunks of 200** (indexed) and image FileTypes. Pull the latest version's Id, Title, FileType, ContentSize, CreatedDate and CreatedBy.Name.
  6. Dedupe by document. Cap at 1,000 images, newest first, with a `truncated` flag past that.
  - **Payload:** one call, no server pagination.
    - About 1,000 lightweight items (short strings, no blobs) is about 300–500 KB of JSON.
    - Client-side search, sort, filter chips and timeline grouping all need the full set, and server pagination would break them.
    - The spike measures the payload size and timing at 1,000 images. Cursor pagination is added only if it's over ~1.5 s on mobile.
- **`getExif(List<Id> versionIds)`: Path B only.**
  - Re-check access in user mode first.
  - Files ≤ 256 KB are read with SOQL `VersionData` within a **1.5 MB total budget per call**. (Gemini's 20 × 256 KB = 5 MB scenario can't happen because of this budget.)
  - Larger files use a Range callout through the Named Credential (verified: 206 with 64 KB of 4.9 MB).
  - Exact APP1 range with no blind retry. Hex conversion of the APP1 segment only. One file at a time.
  - Batch size set by spike measurement (default 20).
- **`ImageExifParser`** (Path B) and the JS parser `exifReader.js` (Path A) follow the same logic:
  - Walk the JPEG markers and scan every APP1 segment.
  - Use the segment with `Exif\0\0` and skip XMP.
  - Handle both endian orders.
  - Read DateTimeOriginal and GPS lat/long with their Refs.
  - APP1 is ≤ 65,535 bytes by spec. If it starts past the first read, make one exact follow-up range.

### 2. LWC `imageGallery` (+ `exifReader.js` module)
- **Targets:**
  - `lightning__RecordPage` for Asset, WorkOrder, WorkStep, WOLI, SA.
  - `lightning__RecordAction` (ScreenAction) for desktop, Field Service mobile and work-step execution on web and mobile.
- **Load flow:**
  1. `getImages` renders the grid at once, sorted by **upload time (default)**.
  2. EXIF loads lazily for cards in view (`IntersectionObserver`) and for the lightbox. At most 4 fetches run at once on Path A, or 2 batches on Path B.
  3. **Cache:** an in-memory `Map` plus `localStorage` (`igx:<versionId>`, LRU at about 5,000 entries).
     - Treated as an **optimistic, volatile** cache, since iOS WebKit can purge it.
     - When the cache is missed, the image is just re-read. Correctness never depends on the cache.
- **Sort:**
  - The default is upload time (CreatedDate), newest or oldest.
  - "Capture time" is an **explicit mode**. Choosing it loads EXIF for every image, with a progress bar, then sorts.
  - Images with no EXIF time are grouped at the end, labelled "No capture time", so the order is never mixed or misleading.
- **Toolbar:**
  - Search over image title, record title, subtitle, object label and breadcrumb.
  - Size S/M/L.
  - Sort mode.
  - Grid/Timeline.
  - Filter chips with counts.
  - Refresh.
  - **Mobile (`FORM_FACTOR === 'Small'`):**
    - S/M/L maps to 3, 2 and 1 columns, so a card is never narrower than about 110 px.
    - The default is 2 columns, with cards at least 160 px wide and tap targets at least 44×44 px.
    - Filter chips move into a bottom drawer (`lightning-button-icon` "Filter").
- **Card:**
  - Lazy rendition `<img>` (`THUMB240BY180`, or `THUMB720BY480` for L).
  - **Rendition gap:** never download the original in the grid. On `onerror`, show a file icon with a "Preview processing" badge and retry once after 15 s. HEIC with no rendition shows a file-type placeholder.
  - Time ("Captured" or "Uploaded").
  - Location with a **maps button** (`standard__webPage` `https://maps.google.com/?q=lat,lng`), which opens natively on mobile. Otherwise "No location".
  - Related record chip (`standard__recordPage`).
  - Breadcrumb.
- **Lightbox:** `THUMB720BY480` plus a "Full size" button for the original, loaded only when tapped. Also shows related records with their dates.
- **Timeline:** groups by day with sticky date headers on a vertical line. Grouped by upload date, or by capture date in capture mode.
- **Speed:** one call for the grid, client-side filter and sort, 120 cards rendered then more on scroll, EXIF never blocking.

### 3. Wiring (no fields or objects)
- **Quick actions** `Image_Gallery` (LWC) on Asset, WorkOrder and WorkStep, added to the page layouts' Mobile & Lightning actions.
- **Work step:** the template's Action Definition is the WorkStep `Image_Gallery` action.
- **Permission set** `Image_Gallery_User`: Apex class access. On Path B, also External Credential principal access.
- **Path A, if CSP blocks it:** a CSP Trusted Site for the org's `*.file.force.com` domain (connect-src).

### 4. Self-callout auth: Path B only (delete if Path A works)
- **External Client App `Image_Gallery_Self`:**
  - Client credentials flow, scope `api`.
  - Run-as user: a dedicated integration user with file read across the gallery's records. Exact permission name checked in the org, and the visibility tested both ways.
  - The consumer key and secret can't be deployed. **Manual step after every deploy or sandbox refresh:** copy them into the principal. This is a real DevOps cost and the main reason Path A is preferred.
- **External Credential** (OAuth 2.0 client credentials) and **Named Credential** `Image_Gallery_Self` pointing at the org's My Domain.
- **Security:** callouts run as the integration user, but the user-mode re-check filters files first. A failed callout returns status `error`.

## Files (`Cursor_2026/Asset WO Image Gallery/force-app/main/default/`)
- `classes/ImageGallerySources`, `ImageGalleryController`, plus `*Test` (each `.cls` with `-meta.xml`)
- `lwc/imageGallery/**`, and `lwc/exifReader/exifReader.js` (a shared JS module), with Jest `__tests__` (EXIF fixtures)
- `quickActions/{Asset,WorkOrder,WorkStep}.Image_Gallery.quickAction-meta.xml`
- `permissionsets/Image_Gallery_User.permissionset-meta.xml`
- Path A only, if needed: `cspTrustedSites/Image_Gallery_Files.cspTrustedSite-meta.xml`
- Path B only: `ImageExifParser.cls`, plus the External Client App, External Credential and Named Credential files (exact folders checked with `platform-metadata-api-context-get`)
- `scripts/apex/seedImages.apex`: attaches GPS-tagged JPEGs across a test Asset tree and WO tree

## Build order
1. **Spike (decides Path A or B):**
   - Build a minimal LWC quick action on WorkOrder and WorkStep with:
     - one rendition `<img>`;
     - a "Full size" link for the 4.9 MB JPEG;
     - a **test button that runs the Range `fetch` on the original and logs the status (206/200), the byte count, the CORS or CSP error if any, and the parsed GPS for a seeded GPS JPEG.**
   - Test on desktop Chrome and Safari, and in Field Service mobile on iOS and Android.
   - If it's blocked by CSP, add the CSP Trusted Site and test again.
   - If it works everywhere, choose **Path A** and drop `getExif` and section 4.
   - If it fails, choose **Path B**: set up the External Client App, External Credential and Named Credential, then measure `getExif` heap, CPU and wall time at 20, 35 and 50 mixed files, and check integration visibility both ways.
   - Also measure:
     - the `getImages` payload size and timing at 1,000 images;
     - whether `localStorage` survives in the mobile webview;
     - the rendition gap on a freshly uploaded image.
2. `ImageGallerySources` and `getImages`, with tests.
3. LWC grid, toolbar, mobile layout, cards, lightbox and timeline, plus Jest tests.
4. EXIF on the chosen path, with parser fixtures (APP0+APP2 before APP1, XMP+EXIF APP1, APP1 past 64 KB) and lazy enrichment.
5. Quick actions, layouts, permission set (plus CSP site or Named Credential as needed) and the work-step template.

## Verification
- Deploy with `sf project deploy start -o rsfieldnov25.demo`. Then run `sf apex run test -o rsfieldnov25.demo -n ImageGalleryControllerTest -r human -c` separately (also `ImageExifParserTest` on Path B), targeting 85%+ coverage.
- Confirm no fields or objects were added. The manifest should contain only ApexClass, LightningComponentBundle, QuickAction, Layout and PermissionSet, plus CspTrustedSite (Path A) or the External Client App, ExternalCredential and NamedCredential (Path B).
- Run `seedImages.apex`, then call `getImages` in anonymous Apex. Check that:
  - every table object appears with a title and date;
  - no Id strings appear in display fields;
  - images are de-duplicated;
  - the descendant filter excludes sibling branches of the root.
- EXIF: the GPS JPEG shows its location. A PNG shows "No location". On Path A, a user without access to a file gets no data back from the fetch.
- **Desktop:** check the record page and quick action on Asset, WO and WorkStep, plus running the work step on web. Cover search, S/M/L, both sort modes, timeline, links, lightbox and the maps button.
- **Field Service mobile (cold restart on iOS):** check the 2-column default, the filter drawer, tap targets, thumbnails, links, the maps button opening natively, and speed with 100+ images.
- Jest: `npm run test:unit`, covering filtering, sort modes, day grouping and the EXIF reader fixtures.

## Known limits
- Location exists only when the photo carries EXIF GPS. Gallery picks or shares on iOS often strip it.
- EXIF is read server-side from the whole file: JPEG up to 10 MB (over 256 KB one per call; 5.5 MB and 7.4 MB verified, nothing above 7.4 MB tested), HEIC up to 2.2 MB. Larger files are skipped. Display is direct from Salesforce.
- Path A costs no API calls. On Path B, only files over 256 KB cost one API call each, once per device while the cache holds. The expected cost for this org is close to 0, since the average JPEG is 23 KB.
- Up to 1,000 images and 5,000 related records per gallery, with a truncated banner past that.
- New uploads show "Preview processing" until Salesforce builds the rendition.

## Photo Hub App Tab (complement to record actions)
A full-screen tab, "Asset & Work Order Photo Hub". It adds to the record actions and doesn't replace them. Both use the same gallery component and the same Apex pipeline. Still no new fields or objects: a tab, a FlexiPage and a global action are setup metadata.

### Facts checked
- **Docs:**
  - `lightning__Tab` works for a custom tab in Lightning Experience and the Salesforce mobile app. It supports no `property` tags.
  - **FS mobile does support custom tabs**, through the Field Service Mobile App Builder (Setup). A tab of type **Lightning Web Component (LWC)** lists the org's LWC global quick actions (`lightning__GlobalAction`), which receive no recordId.
  - A tab of type **LWC Attributes** needs the "Experience Container Salesforce Field Service (ECSFS)" target. The exact target name isn't in the docs search, so verify it before use. That type isn't needed here.
  - So the FS mobile entry point is a **bottom-bar tab** in the App Builder, pointing at the hub's global action. The configuration is assigned per profile.
  - `lightning-map` is **Beta**. It allows at most 10 geocoded addresses per map, so it needs lat/long. About 100 markers are recommended, and it runs in an iframe from `maps.a.forceusercontent.com`.
  - The docs list support in the Salesforce Mobile App. Support in the **FS mobile webview is not documented**, so the spike must test it.
- **Org rsfieldnov25.demo:**
  - Active ServiceResources with a `RelatedRecordId`: 51.
  - AssignedResource records: 4,577.
  - ServiceAppointments scheduled THIS_WEEK: 5, so seed data is needed.
  - Rows with a non-null `Latitude`: WorkOrder 307 of 4,206, Asset 303, ServiceAppointment 1,770.
  - Location fallback sources:
    - WorkOrder `Street` set: 45.
    - WorkOrder `LocationId`: 0.
    - WorkOrder `ServiceTerritoryId`: 4,160.
    - Asset `LocationId`: 6.
    - Asset `Street`: 0.
    - Location with `Latitude`: 5 of 36.
    - ServiceTerritory with `Latitude`: 14 of 18.
  - Assets with a `ParentId`: 691.

### Shell
- **`photoHub` LWC targets** copy the proven pattern in `RS_SupervisorDashboard/.../fieldServiceDashboard.js-meta.xml`:
  - `lightning__AppPage`: desktop full screen, through an App Page FlexiPage and a Lightning Page tab in the app nav.
  - `lightning__HomePage`: optional Home placement.
  - `lightning__RecordPage`: optional; on an Asset or WO page, it opens with that record pre-selected as the root.
  - `lightningCommunity__Page`: Experience site, for partner or contractor techs.
  - `lightning__GlobalAction`: the FS mobile Actions menu, and the App Builder tab of type "LWC" with no settings.
  - **`lightning__ECSFSApp`**: the FS Mobile App Builder tab of type **"LWC Attributes"**, which is the **primary FS mobile entry**. Per the LWC Dev Guide `targets-lightning-ECSFSApp`, its `targetConfig` must contain at least one `property`. Allowed types are Boolean, Integer, String and Picklist, and `datasource` gives static or Apex picklists.
  - A `targetConfig` for `lightning__AppPage,lightning__HomePage` sets `supportedFormFactors` Small + Large.
  - `<targetConfig targets="lightning__ECSFSApp">` uses the same `@api` properties as the App, Home and Record pages, so admins can set up several FS tabs from one component (for example "My Photos" set to My Work, "Photo Map" set to Map, and "Asset Photos" set to Hierarchy):
    ```xml
    <targetConfig targets="lightning__ECSFSApp">
        <property name="defaultMode" type="String" label="Default view" required="true" default="mywork" datasource="mywork,map,hierarchy" description="View shown when the tab opens."/>
        <property name="defaultRange" type="String" label="My Work range" default="week" datasource="today,week" description="Service appointment date range for My Work."/>
        <property name="defaultSize" type="String" label="Thumbnail size" default="M" datasource="S,M,L"/>
        <property name="lockMode" type="Boolean" label="Hide view switcher" default="false" description="Show only the default view."/>
        <property name="maxMarkers" type="Integer" label="Max map markers" default="100" min="10" max="100"/>
    </targetConfig>
    ```
  - The same `property` set is repeated in a `targetConfig` for `lightning__AppPage,lightning__HomePage,lightning__RecordPage,lightningCommunity__Page`. `lightning__GlobalAction` takes no properties, so it uses the JS defaults.
  - `lightning__GlobalAction` gets an explicit `<actionType>ScreenAction</actionType>`, as in `Workshop Kiosk/.../inspectionJobChecklistGlobal`. The action type can't be changed after deploy.
  - `lightning__Tab` isn't needed, because the App Page tab covers desktop.
  - Experience site: community users need Apex class access and sharing on the WO, Asset and SA records. Rendition and servlet URLs under a site prefix may need the `/sitename/` prefix (see memory `kiosk-flow-dcfileview-503`), so test this in the spike.
- A mode switcher (`lightning-tabset`, or a button-group on mobile) offers My Work, Map and Hierarchy. The last mode used is kept in `sessionStorage`.
- Each mode produces an **anchor set** of Asset and WorkOrder Ids. It passes that set to `<c-image-gallery anchor-ids=…>`, which is the same component used on record pages.
  - Refactor: `imageGallery` takes either `recordId` (record context) or `anchorIds` (hub context).
  - Search, sort, size, timeline and the lightbox are all reused unchanged.
- **Apex:**
  - `getImagesForAnchors(String anchorIdsJson)` returns a String (JSON). `getImages(recordId)` becomes a wrapper around it.
  - The record budget (5,000) and image cap (1,000) apply per call. On truncation, the user is told to narrow the scope.

### Mode 1: My Assigned Work
- `ServiceResource WHERE RelatedRecordId = :UserInfo.getUserId() AND IsActive = true`
- Then `AssignedResource WHERE ServiceResourceId = :sr` and `ServiceAppointment.SchedStartTime` = TODAY or THIS_WEEK (a toggle). One query using the parent relationship filter.
- Then each SA's `ParentRecordId` resolves to a WO or WOLI, then the WO, and then the anchors are the WOs plus their Assets.
- The left list (or a top list on mobile) shows each SA's AppointmentNumber, its WO number and Subject, its Asset name and its scheduled time. Selecting one filters the gallery to that WO; "All" shows the union.
- A user with no ServiceResource sees the empty state "No service resource linked to your user".

### Mode 2: Map View (record locations, user decision)
- **Location source:** the record's location, never photo EXIF. Photo cards still show EXIF location in the gallery.
- Each Work Order (and each Asset with no WO) resolves to the **first non-empty source**, in this order:
  1. `WorkOrder.Latitude/Longitude`, which is the geocoded WO address. 307 WOs have it.
  2. `WorkOrder` address (`Street/City/PostalCode/State/Country`), passed as an address marker.
     - `lightning-map` geocodes at most **10 per map**, and any extra are silently ignored.
     - So at most 10 address markers are used. The rest drop to the next source.
  3. `Asset.Latitude/Longitude` (WO `AssetId`): 303.
  4. **Site:** `Location.Latitude/Longitude`, through `WorkOrder.LocationId`, else `Asset.LocationId`. There are only 5 today.
  5. **Territory:** `ServiceTerritory.Latitude/Longitude`, through `WorkOrder.ServiceTerritoryId`. 4,160 WOs have a territory and 14 of 18 territories have coordinates. Shown as **approximate**.
  6. Otherwise the record goes in a "No location" list below the map. It's still clickable and opens the drawer.
- **Precision label:** each marker carries its source ("WO address", "Asset", "Site", "Territory (approx.)"). It's shown in the marker description, and the marker colour comes from a `mapIcon` SVG with a different fill per source.
- **Grouping:**
  - Records that resolve to the same coordinates (5 decimals) merge into **one site marker** with a count. Without this, territory fallbacks pile many WOs on one point.
  - The marker `value` is a site key, never shown. `onmarkerselect` gives that key.
- **Drawer:** an SLDS panel (a full-screen sheet on mobile). It shows the site title (WO number or Asset name, or the territory name for grouped markers), the records at the site, and `<c-image-gallery anchor-ids=[site records]>`.
- **Scope:**
  - Defaults to My Work (this week). It can also be a hierarchy subtree or a picked root Asset.
  - At most **100 markers** (the docs' guidance), after grouping. Past that, only the 100 sites with the most photos are shown, with a "Showing 100 of N sites; filter to narrow" banner.
- **Apex `getMapSites(anchorIdsJson)`:**
  - 1 WorkOrder query with `Asset.Latitude/Longitude`, `Location.Latitude/Longitude`, `ServiceTerritory.Name/Latitude/Longitude` and the address fields, all through parent relationships.
  - Plus 1 Asset query for anchors with no WO.
  - Plus a photo count per site, taken from the same link query.
  - It returns `{siteKey, title, subtitle, source, lat, lng | address, recordCount, photoCount}`, with no Ids except an opaque `siteKey` → anchor map kept on the client.
- **Map settings:** `list-view="visible"` on desktop and `"hidden"` on mobile (the list is shown in the drawer instead). Use `zoom-level` auto, `options={ draggable:true, zoomControl:true }`, and `show-footer` (an "Open in Google Maps" link).
- **Fallback** if `lightning-map` doesn't render in the FS mobile webview: a list of sites sorted by photo count, each with a maps button (`standard__webPage` `https://maps.google.com/?q=lat,lng`).

### Mode 3: Asset Hierarchy Explorer
- **Left:** `lightning-tree-grid` (desktop) or a nested accordion (mobile). Columns: Name, SerialNumber, Status, photo count.
- **Root picker:** a `lightning-record-picker` on Asset (also used to pick a root in Map mode). It's filtered to root Assets, or any asset, which then resolves to its `RootAssetId`.
- **Data:** one flat query, `Asset WHERE RootAssetId = :root`, built into a tree in memory, which is the same query as the record gallery.
  - Lazy expand applies only past 2,000 nodes.
  - Photo counts per node: try one aggregate query on `ContentDocumentLink` (COUNT, GROUP BY `LinkedEntityId`, over the asset Ids, chunked). Whether aggregates are allowed on ContentDocumentLink is **unverified**, so test it in the spike. The fallback is to count from the rows of the plain link query. Counts are per asset only; subtree totals are added in memory.
- **Right:** selecting a node sets anchors to that node plus all its descendants (in memory), which gives the gallery with Asset context (WOs, cases, measures and more).
- **Breadcrumb:** the path from the root to the selected node.

### Hub files
- `lwc/photoHub/**`, `lwc/hubMyWork/**`, `lwc/hubMap/**`, `lwc/hubHierarchy/**`. `imageGallery` gets the `anchorIds` refactor.
- `classes/PhotoHubController` (+Test): `getMyWork(String range)`, `getMapSites(String anchorIdsJson)`, `getAssetTree(Id assetId)`. Each returns a JSON String, uses `with sharing` and user mode.
- `flexipages/Photo_Hub.flexipage-meta.xml` (App Page holding `photoHub`) and `tabs/Photo_Hub.tab-meta.xml` (Lightning Page tab pointing at that FlexiPage).
- Add the tab to an existing Lightning app nav (FSL or the demo app), editing its existing `CustomApplication` metadata.
- `quickActions/Photo_Hub.quickAction-meta.xml` (global, LWC). On FS mobile, the **primary entry** is a Field Service Mobile App Builder tab of type **LWC Attributes**, which picks `photoHub` through `lightning__ECSFSApp` and sets its properties. A tab of type LWC, which uses the global action with defaults, is the alternative. Both are manual App Builder steps, assigned per profile. It can optionally also go in the global publisher layout so it shows in the Actions menu.
- Permission set `Image_Gallery_User` gets the tab visibility and `PhotoHubController` access added.

### Hub build order (after record gallery steps 1–3)
1. Extend the spike: `lightning-map` with 20 lat/long markers inside the FS mobile global action, on iOS and Android; plus the global action opening at full screen.
2. Refactor `imageGallery` to accept `anchorIds`, and add `getImagesForAnchors`.
3. Hierarchy mode, which has the most reuse.
4. My Work mode: seed SAs this week assigned to a test user's ServiceResource.
5. Map mode (location chain above). Seed one WO for each fallback level so every source path is tested.
6. Tab, app nav, global action and publisher layout.

### Hub verification
- Desktop tab, all 3 modes:
  - the My Work counts match `AssignedResource` for the user;
  - selecting a hierarchy node excludes sibling branches;
  - a marker drawer shows only that site's photos;
  - each fallback level plots with the right source label, and records sharing a territory group into one marker;
  - the 100-marker cap and its message;
  - no Ids are displayed.
- FS mobile App Builder tab: modes switch, the map renders (or the list fallback shows), the drawer opens as a full-screen sheet, tap targets are at least 44 px, and a cold start is done on iOS.
- The manifest adds only CustomTab, FlexiPage, QuickAction (global), the CustomApplication edit, and the Layout (global publisher). No fields or objects.

## Build log
- Spike deployed to rsfieldnov25.demo: `ImageGallerySpike` (Apex), `exifReader` and `imageGallerySpike` (LWC), quick actions `WorkOrder.Image_Gallery_Spike` and `WorkStep.Image_Gallery_Spike`. They're added to the layouts `WorkOrder-SDO SFS Work Order Layout` and `WorkStep-SDO - Work Step Layout`. To be deleted after the Path A/B decision.
- GPS test photo: `scripts/fixtures/gps_spike.jpg` (EXIF time 2026-09-15 10:30:00, GPS 37.78972 N, 122.39694 W) uploaded to WO 00012929 as "Gallery Spike GPS Test". `exifReader` parses it correctly in Node.
- Finding: `ContentDocumentLink` requires an equality or `IN` filter on `LinkedEntityId` or `ContentDocumentId`. So a filter by `LinkedEntity.Type` or a GROUP BY over all links is rejected. Hierarchy photo counts must come from the plain link query on explicit Id lists, as already planned.
- SPIKE RESULT (desktop): Path A FAILED. Browser fetch of `/sfc/servlet.shepherd/version/download/<id>` redirects to `https://<org>.file.force.com/...` and is blocked: "No 'Access-Control-Allow-Origin' header is present on the requested resource". It is CORS on the file domain, not CSP, so a CSP Trusted Site cannot fix it. Decision: Path B (server-side EXIF). Delete the Path A fetch code; keep `exifReader.js` logic as the basis for `ImageExifParser.cls`.
- BUILD (Path B, Option 3): deployed `ImageExifParser` (+Test, 7 pass, 86% cov), `ImageGallerySources`, `ImageGalleryController` (`getImages`, `getExif`; +Test, 8 pass, SeeAllData=true because the "SDO SFS Attach Forms On Create" flow blocks WO inserts in isolated tests), LWC `imageGallery`, quick actions `{WorkOrder,Asset,WorkStep}.Image_Gallery`, permission set `Image_Gallery_User` (class access only). Live check on WO 00012929: 26 records, 1 image, EXIF 37.789722/-122.396944 correct, getImages ~0.7-1.2 s warm. Not yet placed on layouts/pages. EXIF skipped for files >256 KB or non-JPEG (Option 3 phase 2 = Named Credential range read, only if needed). Breadcrumb built later (see below). Spike artifacts still to delete.
- HEIC: Salesforce reports HEIC/HEIF as FileType UNKNOWN, so the gallery matches by FileExtension. `ImageExifParser` now also reads ISO-BMFF (ftyp, meta > iinf infe type 'Exif' + iloc extent, 4-byte TIFF offset, then shared TIFF/GPS reader). Bytes are read from base64 text, not hex (less heap). `getExif` accepts heic/heif up to 2.2 MB; budget is 2.4x file size per call against 4.8 MB. Tests: ImageExifParserTest 11 pass (synthetic HEIC v2/v3, iloc v0/v1, LE), ImageGalleryControllerTest 8 pass. Real org file IMG_4692 (2.1 MB): GPS -38.043728, 145.367067, 2026-10-06T10:23:33, 115 ms CPU. Thumbnails for HEIC still unverified.
- BREADCRUMB (2026-10-07): `ImageGallerySources.applyBreadcrumbs` names the trail Asset › parent Work Orders › Work Order › record, by name or number, no Ids sent (`parentId`/`assetId` are transient). Sources gained `parentField`/`assetField` (Asset.ParentId, WorkOrder.ParentWorkOrderId/AssetId, Case.AssetId, Measure_Point__c.Asset__c, SDO_SCOM_Replacement_Parts__c.Asset__c). Only records inside the gallery's context are named, so ancestors above the record the gallery was opened from are omitted (checked on Measure Point "Axel Drive A23": trail is its asset only, as its parent asset is outside the context). Shown on the card and in the lightbox's related records; included in search. `getImages` errors now surface their message (`withMessage`).
- LARGE JPEG EXIF (2026-10-07): `getExif` reads JPEG up to 10 MB, one large file per call (heap budget); the LWC sends JPEGs over 256 KB and HEIC one per call. `ImageGalleryControllerTest` reads the org's real files "Downtown Melbourne" (5.55 MB) and "Racing in Philip Island" (7.36 MB) through `getExif` and asserts GPS and capture time (pass). Files above 10 MB or larger than the heap would need the Named Credential range read, not built.
- UI (2026-10-07): lightbox close button made visible (bordered, dark icon). Map pin colours: blue = EXIF, green = ContentVersion record fields (`locSrc: record`), red = Work Order address fallback.
- VIOLATION FLAGS (2026-10-07): `Source.geo`/`startField` and `ImageGallerySources.applyFences` give each record `places` (own, owning Work Order, Asset; Latitude/Longitude, verified present on WorkOrder, ServiceAppointment, Asset) and `starts` (ServiceAppointment SchedStartTime: the appointment's own, else those under the Work Order or its line items). Raw coordinates are transient. The LWC compares the photo with them: location violation when further than `GEOFENCE_METERS` (100 m) from every place, time violation when further than `TIME_FENCE_MS` (2 h) from every start. Places without coordinates are skipped; no flag when there is nothing to check. EXIF times have no time zone, so they are read in the viewer's browser time zone. Card shows red "Too far from site" / "Off schedule"; the lightbox shows the detail.
- SORTING (2026-10-07): added sort modes Violations (groups: location and time, location, time, none) and Object (groups by the photo's first record, in source order); both newest-upload-first within a group, direction button reverses group order. Violations loads EXIF for all photos first, like Capture time.
- TESTS (2026-10-07): `ImageGalleryControllerTest` 17 pass in rsfieldnov25.demo (breadcrumb x2, large JPEG x2, places/starts x2 added). The LWC logic (distance, time maths, grouping) has no Jest tests and is not yet checked in the browser.
- README.md rewritten to describe the project.
- SPIKE CLEANUP (2026-10-07): deleted the org file "Gallery Spike GPS Test" (WO 00012929) and local `scripts/fixtures/gps_spike.jpg`. The spike Apex class, LWCs (`exifReader`, `imageGallerySpike`) and `*.Image_Gallery_Spike` quick actions were already absent from the org (checked by listing metadata) and from `force-app`.
- CONTENTVERSION FIELDS IN PROJECT (2026-11-06): the optional fallback fields already existed in `rsfieldnov25.demo` but were not in the repo, so a deploy to a new org would not create them. Retrieved `ContentVersion.Capture_Time__c` (DateTime) and `ContentVersion.Geolocation__c` (Location, decimal, scale 6) into `force-app/main/default/objects/ContentVersion/` (plus the empty `ContentVersion.object-meta.xml` stub). `Geolocation__Latitude__s` / `__Longitude__s`, which the code reads, are sub-fields of `Geolocation__c`. `Image_Gallery_User` now grants read-only field permissions on both. Not yet deployed or tested in a clean org. Checked in code (not run): missing objects are skipped (`ImageGallerySources.fetch` returns empty when the object is absent, `usable()` drops missing fields) and missing ContentVersion fields are skipped (`readableRecordFields`).
- STILL OPEN: place the quick actions on layouts and pages; Photo Hub tab not started; HEIC thumbnails unverified.
