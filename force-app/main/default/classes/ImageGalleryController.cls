/**
 * Backs the image gallery LWC. Everything is read live: no custom fields, objects or metadata.
 * Both methods return JSON strings (typed DTOs null out across the LWC boundary).
 */
public with sharing class ImageGalleryController {
    private static final Integer MAX_RECORDS = 5000;
    private static final Integer MAX_IMAGES = 1000;
    private static final Integer CHUNK_SIZE = 200;
    private static final Integer MAX_TREE_ROWS = 10000;
    private static final Integer EXIF_FILE_LIMIT = 262144; // 256 KB per JPEG
    private static final Integer EXIF_HEIC_LIMIT = 2306867; // 2.2 MB per HEIC (blob + base64 copy must fit the 6 MB heap)
    private static final Decimal EXIF_HEAP_FACTOR = 2.4; // heap cost per file byte: blob plus its base64 text
    private static final Integer EXIF_HEAP_BUDGET = 5500000; // heap spent on file bytes per call
    private static final Set<String> IMAGE_TYPES = new Set<String>{ 'JPG', 'JPEG', 'PNG', 'GIF', 'HEIC', 'WEBP', 'BMP' };
    // Salesforce reports HEIC/HEIF as FileType UNKNOWN, so those are matched by extension
    private static final Set<String> IMAGE_EXTENSIONS = new Set<String>{ 'heic', 'heif' };
    private static final Set<String> EXIF_TYPES = new Set<String>{ 'JPG', 'JPEG' };
    // Optional ContentVersion fields captured by the upload app; used only when the file has no EXIF value
    private static final String RECORD_TIME_FIELD = 'Capture_Time__c';
    private static final String RECORD_LAT_FIELD = 'Geolocation__Latitude__s';
    private static final String RECORD_LNG_FIELD = 'Geolocation__Longitude__s';

    /**
     * @param recordId Asset, WorkOrder, WorkStep, WorkOrderLineItem or ServiceAppointment Id
     * @return JSON {truncated, reason, records[], images[]}; images reference records by index
     */
    @AuraEnabled
    public static String getImages(Id recordId) {
        if (recordId == null) {
            throw new AuraHandledException('No record to show images for.');
        }
        try {
            Map<String, Object> out = new Map<String, Object>{
                'truncated' => false,
                'reason' => null,
                'baseUrl' => URL.getOrgDomainUrl().toExternalForm() // relative URLs do not resolve in Field Service mobile
            };
            Map<String, Set<Id>> sets = buildContext(recordId);
            List<ImageGallerySources.Rec> records = new List<ImageGallerySources.Rec>();
            Integer remaining = MAX_RECORDS;
            for (ImageGallerySources.Source source : ImageGallerySources.all()) {
                List<ImageGallerySources.Rec> found = ImageGallerySources.fetch(source, sets, remaining);
                records.addAll(found);
                remaining -= found.size();
                if (remaining <= 0) {
                    out.put('truncated', true);
                    out.put('reason', 'Too many related records; showing the most recent.');
                    break;
                }
            }
            ImageGallerySources.applyWorkOrderAddresses(records);
            out.put('records', records);
            out.put('images', findImages(records, out));
            return JSON.serialize(out);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException('Could not load images: ' + e.getMessage());
        }
    }

    /**
     * Reads capture time and GPS from the original files' EXIF. JPEG over 256 KB or HEIC over 2.2 MB,
     * other formats, and files past the per-call heap budget are reported as 'skipped'. Where EXIF has
     * no time or position, ContentVersion Capture_Time__c / Geolocation__c are used when they exist.
     * @param versionIds ContentVersion Ids
     * @return JSON {versionId: {s: ok|none|skipped, t: capturedAt, lat, lng, tSrc, locSrc: exif|record}}
     */
    @AuraEnabled
    public static String getExif(List<Id> versionIds) {
        Map<Id, Map<String, Object>> out = new Map<Id, Map<String, Object>>();
        if (versionIds == null || versionIds.isEmpty()) {
            return JSON.serialize(out);
        }
        try {
            List<Id> eligible = new List<Id>();
            Integer budget = 0;
            List<String> extraFields = readableRecordFields();
            Map<Id, ContentVersion> metas = new Map<Id, ContentVersion>((List<ContentVersion>) Database.queryWithBinds(
                'SELECT Id, ContentSize, FileType, FileExtension' + (extraFields.isEmpty() ? '' : ', ' + String.join(extraFields, ', '))
                    + ' FROM ContentVersion WHERE Id IN :versionIds',
                new Map<String, Object>{ 'versionIds' => versionIds },
                AccessLevel.USER_MODE
            ));
            for (ContentVersion meta : metas.values()) {
                Boolean heic = IMAGE_EXTENSIONS.contains(meta.FileExtension?.toLowerCase());
                Integer cost = Integer.valueOf(meta.ContentSize * EXIF_HEAP_FACTOR);
                Boolean fits = ((EXIF_TYPES.contains(meta.FileType) && meta.ContentSize <= EXIF_FILE_LIMIT)
                    || (heic && meta.ContentSize <= EXIF_HEIC_LIMIT))
                    && budget + cost <= EXIF_HEAP_BUDGET;
                if (fits) {
                    budget += cost;
                    eligible.add(meta.Id);
                }
                out.put(meta.Id, exifEntry(fits ? 'none' : 'skipped', null));
            }
            if (!eligible.isEmpty()) {
                for (ContentVersion version : [SELECT Id, VersionData FROM ContentVersion WHERE Id IN :eligible WITH USER_MODE]) {
                    out.put(version.Id, exifEntry('none', ImageExifParser.parse(version.VersionData)));
                }
            }
            for (Id versionId : out.keySet()) {
                applyRecordFallback(out.get(versionId), metas.get(versionId), extraFields);
            }
            return JSON.serialize(out);
        } catch (Exception e) {
            throw new AuraHandledException('Could not read photo details: ' + e.getMessage());
        }
    }

    /**
     * Returns the original file bytes so the LWC can show them in the modal instead of downloading.
     * Capped at 2.2 MB: blob plus its base64 text must fit the 6 MB heap and the response size limit.
     * @param versionId ContentVersion Id
     * @return JSON {ok, base64, mime, reason}
     */
    @AuraEnabled
    public static String getFileData(Id versionId) {
        Map<String, Object> out = new Map<String, Object>{ 'ok' => false };
        if (versionId == null) {
            return JSON.serialize(out);
        }
        try {
            List<ContentVersion> metas = [
                SELECT Id, ContentSize, FileExtension FROM ContentVersion WHERE Id = :versionId WITH USER_MODE LIMIT 1
            ];
            if (metas.isEmpty()) {
                out.put('reason', 'not found');
            } else if (metas[0].ContentSize > EXIF_HEIC_LIMIT) {
                out.put('reason', 'too large');
            } else {
                ContentVersion version = [SELECT VersionData FROM ContentVersion WHERE Id = :versionId WITH USER_MODE];
                out.put('base64', EncodingUtil.base64Encode(version.VersionData));
                out.put('mime', metas[0].FileExtension?.toLowerCase());
                out.put('ok', true);
            }
            return JSON.serialize(out);
        } catch (Exception e) {
            throw new AuraHandledException('Could not load the photo: ' + e.getMessage());
        }
    }

    private static List<String> readableRecordFields() {
        List<String> fields = new List<String>();
        Map<String, Schema.SObjectField> all = Schema.SObjectType.ContentVersion.fields.getMap();
        for (String name : new List<String>{ RECORD_TIME_FIELD, RECORD_LAT_FIELD, RECORD_LNG_FIELD }) {
            Schema.SObjectField field = all.get(name);
            if (field != null && field.getDescribe().isAccessible()) {
                fields.add(name);
            }
        }
        return fields;
    }

    private static void applyRecordFallback(Map<String, Object> entry, ContentVersion meta, List<String> fields) {
        if (entry.get('t') != null) {
            entry.put('tSrc', 'exif');
        } else if (meta != null && fields.contains(RECORD_TIME_FIELD) && meta.get(RECORD_TIME_FIELD) != null) {
            entry.put('t', ((Datetime) meta.get(RECORD_TIME_FIELD)).formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\''));
            entry.put('tSrc', 'record');
        }
        if (entry.get('lat') != null) {
            entry.put('locSrc', 'exif');
        } else if (meta != null && fields.contains(RECORD_LAT_FIELD) && fields.contains(RECORD_LNG_FIELD)
            && meta.get(RECORD_LAT_FIELD) != null && meta.get(RECORD_LNG_FIELD) != null) {
            entry.put('lat', ((Decimal) meta.get(RECORD_LAT_FIELD)).setScale(6));
            entry.put('lng', ((Decimal) meta.get(RECORD_LNG_FIELD)).setScale(6));
            entry.put('locSrc', 'record');
        }
    }

    private static Map<String, Object> exifEntry(String status, ImageExifParser.Result parsed) {
        Map<String, Object> entry = new Map<String, Object>{ 's' => status };
        if (parsed != null) {
            entry.put('s', parsed.status);
            entry.put('t', parsed.capturedAt);
            entry.put('lat', parsed.lat);
            entry.put('lng', parsed.lng);
        }
        return entry;
    }

    // ---- images ----

    private static List<Map<String, Object>> findImages(List<ImageGallerySources.Rec> records, Map<String, Object> out) {
        Map<Id, Integer> indexById = new Map<Id, Integer>();
        for (Integer i = 0; i < records.size(); i++) {
            indexById.put(records[i].id, i);
        }
        Map<Id, Map<String, Object>> byDocument = new Map<Id, Map<String, Object>>();
        List<Id> linkedIds = new List<Id>(indexById.keySet());
        for (Integer start = 0; start < linkedIds.size(); start += CHUNK_SIZE) {
            List<Id> chunk = new List<Id>();
            for (Integer i = start; i < Math.min(start + CHUNK_SIZE, linkedIds.size()); i++) {
                chunk.add(linkedIds[i]);
            }
            for (ContentDocumentLink link : [
                SELECT LinkedEntityId, ContentDocumentId, ContentDocument.Title, ContentDocument.FileType,
                    ContentDocument.FileExtension, ContentDocument.ContentSize, ContentDocument.CreatedDate, ContentDocument.CreatedBy.Name,
                    ContentDocument.LatestPublishedVersionId
                FROM ContentDocumentLink
                WHERE LinkedEntityId IN :chunk
                WITH USER_MODE
            ]) {
                if (isImage(link.ContentDocument)) {
                    addLink(byDocument, link, indexById.get(link.LinkedEntityId));
                }
            }
        }
        List<Map<String, Object>> images = byDocument.values();
        images.sort(new NewestFirst());
        if (images.size() > MAX_IMAGES) {
            out.put('truncated', true);
            out.put('reason', 'More than ' + MAX_IMAGES + ' images; showing the newest.');
            while (images.size() > MAX_IMAGES) {
                images.remove(images.size() - 1);
            }
        }
        return images;
    }

    private static Boolean isImage(ContentDocument doc) {
        return IMAGE_TYPES.contains(doc.FileType?.toUpperCase()) || IMAGE_EXTENSIONS.contains(doc.FileExtension?.toLowerCase());
    }

    private static void addLink(Map<Id, Map<String, Object>> byDocument, ContentDocumentLink link, Integer recordIndex) {
        Map<String, Object> image = byDocument.get(link.ContentDocumentId);
        if (image == null) {
            ContentDocument doc = link.ContentDocument;
            image = new Map<String, Object>{
                'versionId' => doc.LatestPublishedVersionId,
                'title' => doc.Title,
                'fileType' => doc.FileType == 'UNKNOWN' ? doc.FileExtension?.toUpperCase() : doc.FileType,
                'size' => doc.ContentSize,
                'uploaded' => doc.CreatedDate,
                'uploadedBy' => doc.CreatedBy?.Name,
                'refs' => new List<Integer>()
            };
            byDocument.put(link.ContentDocumentId, image);
        }
        ((List<Integer>) image.get('refs')).add(recordIndex);
    }

    /** Sorts image maps by upload time, newest first. */
    private class NewestFirst implements System.Comparator<Map<String, Object>> {
        public Integer compare(Map<String, Object> a, Map<String, Object> b) {
            Datetime left = (Datetime) a.get('uploaded');
            Datetime right = (Datetime) b.get('uploaded');
            return left == right ? 0 : (left < right ? 1 : -1);
        }
    }

    // ---- context: which Assets / Work Orders / Cases / Line Items belong to the gallery ----

    private static Map<String, Set<Id>> buildContext(Id recordId) {
        String type = recordId.getSObjectType().getDescribe().getName();
        Set<Id> workOrderSeeds = new Set<Id>();
        Set<Id> assetIds = new Set<Id>();
        if (type == 'Asset') {
            assetIds = assetSubtree(recordId);
            for (WorkOrder wo : [SELECT Id FROM WorkOrder WHERE AssetId IN :assetIds WITH USER_MODE LIMIT :MAX_TREE_ROWS]) {
                workOrderSeeds.add(wo.Id);
            }
        } else {
            workOrderSeeds.add(owningWorkOrderId(recordId, type));
        }
        Map<String, Set<Id>> sets = new Map<String, Set<Id>>();
        Set<Id> workOrderIds = workOrderSubtrees(workOrderSeeds);
        Set<Id> caseIds = new Set<Id>();
        for (WorkOrder wo : [SELECT AssetId, CaseId FROM WorkOrder WHERE Id IN :workOrderIds WITH USER_MODE]) {
            if (type != 'Asset' && wo.AssetId != null) {
                assetIds.add(wo.AssetId);
            }
            if (wo.CaseId != null) {
                caseIds.add(wo.CaseId);
            }
        }
        for (Case c : [SELECT Id FROM Case WHERE AssetId IN :assetIds WITH USER_MODE LIMIT :MAX_TREE_ROWS]) {
            caseIds.add(c.Id);
        }
        Set<Id> lineItemIds = new Set<Id>();
        for (WorkOrderLineItem item : [SELECT Id FROM WorkOrderLineItem WHERE WorkOrderId IN :workOrderIds WITH USER_MODE LIMIT :MAX_TREE_ROWS]) {
            lineItemIds.add(item.Id);
        }
        Set<Id> parents = new Set<Id>(workOrderIds);
        parents.addAll(lineItemIds);
        sets.put(ImageGallerySources.SET_ASSET, assetIds);
        sets.put(ImageGallerySources.SET_WO, workOrderIds);
        sets.put(ImageGallerySources.SET_WOLI, lineItemIds);
        sets.put(ImageGallerySources.SET_CASE, caseIds);
        sets.put(ImageGallerySources.SET_WO_WOLI, parents);
        return sets;
    }

    /** Resolves WorkStep, line item, appointment or Work Order Ids to their Work Order. */
    private static Id owningWorkOrderId(Id recordId, String type) {
        if (type == 'WorkOrder') {
            return recordId;
        }
        SystemResolver resolver = new SystemResolver();
        Id parentId = resolver.parentOf(recordId, type);
        if (parentId != null && parentId.getSObjectType().getDescribe().getName() == 'WorkOrderLineItem') {
            parentId = resolver.parentOf(parentId, 'WorkOrderLineItem');
        }
        if (parentId == null) {
            throw new AuraHandledException('Images are not available for this record.');
        }
        return parentId;
    }

    /** Finds the parent Work Order (or line item, for appointments) of a record; WorkStep is Private OWD. */
    private without sharing class SystemResolver {
        public Id parentOf(Id recordId, String type) {
            String field = type == 'ServiceAppointment' ? 'ParentRecordId' : 'WorkOrderId';
            if (type != 'WorkStep' && type != 'WorkOrderLineItem' && type != 'ServiceAppointment') {
                return null;
            }
            List<SObject> rows = Database.query(
                'SELECT ' + field + ' FROM ' + type + ' WHERE Id = :recordId LIMIT 1', AccessLevel.SYSTEM_MODE
            );
            return rows.isEmpty() ? null : (Id) rows[0].get(field);
        }
    }

    /** The anchor Asset and all of its descendants, from one RootAssetId query. */
    private static Set<Id> assetSubtree(Id anchorId) {
        Asset anchor = [SELECT Id, RootAssetId FROM Asset WHERE Id = :anchorId WITH USER_MODE];
        Id rootId = anchor.RootAssetId ?? anchor.Id;
        Map<Id, List<Id>> childrenByParent = new Map<Id, List<Id>>();
        for (Asset a : [SELECT Id, ParentId FROM Asset WHERE RootAssetId = :rootId WITH USER_MODE LIMIT :MAX_TREE_ROWS]) {
            addChild(childrenByParent, a.ParentId, a.Id);
        }
        return descendants(new Set<Id>{ anchorId }, childrenByParent);
    }

    /** The seed Work Orders and all of their descendants. */
    private static Set<Id> workOrderSubtrees(Set<Id> seeds) {
        if (seeds.isEmpty()) {
            return seeds;
        }
        Set<Id> roots = new Set<Id>();
        for (WorkOrder wo : [SELECT Id, RootWorkOrderId FROM WorkOrder WHERE Id IN :seeds WITH USER_MODE]) {
            roots.add(wo.RootWorkOrderId ?? wo.Id);
        }
        Map<Id, List<Id>> childrenByParent = new Map<Id, List<Id>>();
        for (WorkOrder wo : [
            SELECT Id, ParentWorkOrderId FROM WorkOrder WHERE RootWorkOrderId IN :roots WITH USER_MODE LIMIT :MAX_TREE_ROWS
        ]) {
            addChild(childrenByParent, wo.ParentWorkOrderId, wo.Id);
        }
        return descendants(seeds, childrenByParent);
    }

    private static void addChild(Map<Id, List<Id>> childrenByParent, Id parentId, Id childId) {
        if (parentId == null) {
            return;
        }
        if (!childrenByParent.containsKey(parentId)) {
            childrenByParent.put(parentId, new List<Id>());
        }
        childrenByParent.get(parentId).add(childId);
    }

    private static Set<Id> descendants(Set<Id> seeds, Map<Id, List<Id>> childrenByParent) {
        Set<Id> result = new Set<Id>(seeds);
        List<Id> queue = new List<Id>(seeds);
        while (!queue.isEmpty()) {
            Id next = queue.remove(queue.size() - 1);
            for (Id child : childrenByParent.get(next) ?? new List<Id>()) {
                if (result.add(child)) {
                    queue.add(child);
                }
            }
        }
        return result;
    }
}
