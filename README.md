# Asset / Work Order Image Gallery

A Lightning Web Component that shows every photo attached to an Asset or Work Order and its related records, in one gallery. Nothing is stored by the gallery. Everything is read live from the org. The only custom metadata in the project is two optional `ContentVersion` fields (`Capture_Time__c`, `Geolocation__c`) that the gallery reads and never writes.

Target org: `rsfieldnov25.demo` (flagged as Production by the deploy-gate hook, so deploys need `CONFIRM_PROD=1`). Source API version 67.0.

See `PLAN.md` for the design, verified org facts and build log.

## What it does

- Collects image files (JPG, PNG, GIF, HEIC, WEBP, BMP) linked to the record the gallery is opened from and its related records:
  Asset (and child assets), Work Order, Work Order Line Item, Work Plan, Work Step, Service Appointment, Case, Measure Point, Work Delay, Safety Incident, Time Report, Purchase Order, Replacement Parts.
- Opens from an Asset, Work Order or Work Step quick action, or standalone (a picker chooses the Work Order or Asset).
- Grid and timeline views, thumbnail sizes S/M/L, search across photo titles, uploader, record names and breadcrumbs.
- Lightbox with the related records, capture time, location and a "View full size" button that shows the original inline instead of downloading it.

### Breadcrumb

Each photo shows the trail of the record it belongs to, by name only, for example `Asset › parent Work Order › Work Order`. Only records inside the gallery's context are named, so ancestors above the record the gallery was opened from are left out. It is searchable.

### Capture time and location (EXIF)

- Read lazily, so the grid never waits for it. JPEGs up to 10 MB (files over 256 KB are read one per call) and HEIC up to 2.2 MB. Other formats and larger files are skipped.
- Where the file has no EXIF value, the ContentVersion fields `Capture_Time__c` and `Geolocation__c` (read as `Geolocation__Latitude__s` / `Geolocation__Longitude__s`) are used when they exist and the user can read them. Both field definitions are in the project and deploy with it; without them the gallery uses EXIF only.
- Map pin colour: **blue** = location from EXIF, **green** = location from the ContentVersion record fields, **red** = Work Order address fallback (photo has no location of its own).

### Violation flags

- **Location:** the photo is further than `GEOFENCE_METERS` (100 m) from every place it is checked against: the photo's record, its Work Order, its Asset and a linked Service Appointment, using their stored Latitude/Longitude. Places with no coordinates are skipped.
- **Time:** the capture time is further than `TIME_FENCE_MS` (2 h) from the scheduled start of every relevant Service Appointment. A photo on an appointment uses that appointment; any other photo uses the appointments under its Work Order or line items.
- Both limits are constants at the top of `imageGallery.js`.
- EXIF times carry no time zone, so they are read in the viewer's browser time zone.
- Nothing is flagged when there is nothing to check against (no coordinates, no appointment, no location or time on the photo).

### Sorting

Upload time, Capture time, **Violations** (grouped: location and time, location, time, none) and **Object** (grouped by the first record the photo belongs to: Asset, Work Order, line item, and so on). The direction button reverses the order.

## User instructions: components and actions

The gallery is one Lightning Web Component, `imageGallery` (label "Image Gallery"). Deploying the project does not place it anywhere: an admin adds it to pages or layouts, as below.

### 1. Give users access

Assign the permission set **Image Gallery User**. It grants the Apex classes and read-only access to the two ContentVersion fields. Users also need normal read access to the records and files they want to see.

### 2. Choose where it appears

| Where | What to add | Works on |
|---|---|---|
| Record page | Drag the **Image Gallery** component onto the page in Lightning App Builder | Asset, Work Order, Work Step, Work Order Line Item, Service Appointment (desktop and mobile) |
| Record quick action | Add the **Image Gallery** action to the object's page layout under Mobile & Lightning Actions | Asset (`Asset.Image_Gallery`), Work Order (`WorkOrder.Image_Gallery`), Work Step (`WorkStep.Image_Gallery`) |
| Global quick action | Add the global **Image Gallery** action (`Image_Gallery`) to the global publisher layout. It opens with no record, and a picker chooses the Work Order or Asset. | Anywhere global actions show |
| App page | Drag the component onto a Lightning App Page | Desktop and mobile |
| Home page | Drag the component onto the Home page | Desktop and mobile |

The four quick actions are all the same component. Only their object differs.

### 3. Using it

- Opened from a record, the gallery shows that record's photos and those of its related records (see "What it does").
- Opened without a record (global action, app page, home page), choose a Work Order or Asset first.
- Pick Grid or Timeline, thumbnail size S/M/L, a sort, and search. Click a photo for the lightbox, where "View full size" shows the original.

### Not placed by this project

The project contains the actions and the component but **does not add them to any layout or Flexipage**. Placement is a manual admin step, so existing page layouts are never overwritten on deploy.

## Files (`force-app/main/default/`)

| Path | Purpose |
|---|---|
| `lwc/imageGallery` | The gallery UI |
| `classes/ImageGalleryController.cls` | `getImages`, `getExif`, `getFileData` (all return JSON strings) |
| `classes/ImageGallerySources.cls` | Record types shown, queries, breadcrumbs, geofence and time-fence data |
| `classes/ImageExifParser.cls` | JPEG and HEIC EXIF reader |
| `classes/ImageGalleryControllerTest.cls`, `ImageExifParserTest.cls` | Tests (the controller test uses `SeeAllData=true`) |
| `quickActions/` | Image Gallery actions for Asset, Work Order, Work Step and a global action |
| `objects/ContentVersion/fields/` | `Capture_Time__c` (DateTime) and `Geolocation__c` (Location), the optional record-level fallback for capture time and location |
| `permissionsets/Image_Gallery_User.permissionset-meta.xml` | Access to the gallery classes, plus read-only field access to the two ContentVersion fields |
| `flexipages/`, `layouts/` | Pages and layouts the actions were added to |

## Deploy and test

```bash
# deploy the gallery only
CONFIRM_PROD=1 sf project deploy start \
  --source-dir force-app/main/default/classes --source-dir force-app/main/default/lwc \
  --target-org rsfieldnov25.demo --wait 20

# deploy runs no tests, so run them separately
sf apex run test --class-names ImageGalleryControllerTest --class-names ImageExifParserTest \
  --target-org rsfieldnov25.demo --result-format human --wait 20 --code-coverage
```

`ImageGalleryControllerTest` reads two real large JPEGs that already exist in the org ("Downtown Melbourne" and "Racing in Philip Island"); a test returns early if its file is missing.

## Known limits

- Files over the Apex heap limits cannot get EXIF; a Range-request callout through a Named Credential would be needed and is not built.
- Photos linked to several records are grouped and breadcrumbed by the first record only.
- Each Rec carries its places and start times, so very large galleries (up to 5,000 records, 1,000 images) send a bigger payload.
