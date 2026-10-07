/** Tests for ImageGalleryController using generated Asset/Work Order/file data. */
// SeeAllData=true: the org's "SDO SFS Attach Forms On Create" flow blocks WorkOrder inserts in isolated tests.
@IsTest(SeeAllData=true)
private class ImageGalleryControllerTest {
    private static final String GPS_JPEG_HEX = 'ffd8ffe100ba4578696600004d4d002a00000008000287690004000000010000002688250004000000010000003800000000000190030002000000140000006e00000000000400010002000000024e00000000020005000000030000008200030002000000025700000000040005000000030000009a00000000323032363a30393a31352031303a33303a30300000000025000000010000002f00000001000008fc000000640000007a0000000100000017000000010000003100000001ffd9';

    private static void makeData() {
        Account account = new Account(Name = 'Gallery Account GT7');
        insert account;
        Asset parent = new Asset(Name = 'Gallery Parent Asset GT7', AccountId = account.Id);
        insert parent;
        Asset child = new Asset(Name = 'Gallery Child Asset GT7', ParentId = parent.Id, AccountId = account.Id);
        insert child;
        WorkOrder order = new WorkOrder(Subject = 'Gallery order GT7', AssetId = child.Id);
        insert order;
        attach(order.Id, 'Order photo GT7', EncodingUtil.convertFromHex(GPS_JPEG_HEX), 'order.jpg');
        attach(child.Id, 'Child asset photo GT7', Blob.valueOf('not really a png'), 'asset.png');
        attach(order.Id, 'Heic photo GT7', Blob.valueOf('not really a heic'), 'phone.heic');
        attach(order.Id, 'Notes file GT7', Blob.valueOf('plain text'), 'notes.txt');
    }

    private static void attach(Id parentId, String title, Blob body, String path) {
        ContentVersion version = new ContentVersion(Title = title, PathOnClient = path, VersionData = body);
        insert version;
        Id documentId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :version.Id].ContentDocumentId;
        insert new ContentDocumentLink(LinkedEntityId = parentId, ContentDocumentId = documentId, ShareType = 'V');
    }

    private static Map<String, Object> load(Id recordId) {
        return (Map<String, Object>) JSON.deserializeUntyped(ImageGalleryController.getImages(recordId));
    }

    private static Set<String> imageTitles(Map<String, Object> payload) {
        Set<String> titles = new Set<String>();
        for (Object image : (List<Object>) payload.get('images')) {
            titles.add((String) ((Map<String, Object>) image).get('title'));
        }
        return titles;
    }

    @IsTest
    static void shouldReturnOrderImages_WhenWorkOrderAnchor() {
        makeData();
        WorkOrder order = [SELECT Id FROM WorkOrder WHERE Subject = 'Gallery order GT7' LIMIT 1];
        Test.startTest();
        Map<String, Object> payload = load(order.Id);
        Test.stopTest();
        Set<String> titles = imageTitles(payload);
        Assert.isTrue(titles.contains('Order photo GT7'), 'Order photo should be listed');
        Assert.isTrue(titles.contains('Child asset photo GT7'), 'Photo on the order asset should be listed');
        Assert.isFalse(titles.contains('Notes file GT7'), 'Non-image files are excluded');
        Assert.isTrue(titles.contains('Heic photo GT7'), 'HEIC is matched by extension');
    }

    @IsTest
    static void shouldReturnWorkOrderAddress_WhenOrderHasAddress() {
        makeData();
        WorkOrder order = [SELECT Id FROM WorkOrder WHERE Subject = 'Gallery order GT7' LIMIT 1];
        order.Street = '1 Gallery Street';
        order.City = 'Melbourne';
        order.PostalCode = '3000';
        update order;
        Test.startTest();
        Map<String, Object> payload = load(order.Id);
        Test.stopTest();
        String address;
        for (Object item : (List<Object>) payload.get('records')) {
            Map<String, Object> rec = (Map<String, Object>) item;
            if (rec.get('id') == order.Id) {
                address = (String) rec.get('address');
                Assert.isFalse(rec.containsKey('workOrderId'), 'The owning order Id is not sent to the client');
            }
        }
        Assert.areEqual('1 Gallery Street, Melbourne, 3000', address, 'Address is built from the order address fields');
    }

    @IsTest
    static void shouldReturnDescendantImages_WhenParentAssetAnchor() {
        makeData();
        Asset parent = [SELECT Id FROM Asset WHERE Name = 'Gallery Parent Asset GT7'];
        Test.startTest();
        Map<String, Object> payload = load(parent.Id);
        Test.stopTest();
        Set<String> titles = imageTitles(payload);
        Assert.isTrue(titles.contains('Child asset photo GT7'), 'Child asset photo should roll up');
        Assert.isTrue(titles.contains('Order photo GT7'), 'Order photo of the child asset should roll up');
    }

    @IsTest
    static void shouldExcludeSiblingBranch_WhenChildAssetAnchor() {
        makeData();
        Asset parent = [SELECT Id FROM Asset WHERE Name = 'Gallery Parent Asset GT7'];
        Asset sibling = new Asset(Name = 'Sibling Asset GT7', ParentId = parent.Id, AccountId = [SELECT AccountId FROM Asset WHERE Id = :parent.Id].AccountId);
        insert sibling;
        attach(sibling.Id, 'Sibling photo GT7', Blob.valueOf('x'), 'sibling.png');
        Asset child = [SELECT Id FROM Asset WHERE Name = 'Gallery Child Asset GT7'];
        Test.startTest();
        Map<String, Object> payload = load(child.Id);
        Test.stopTest();
        Assert.isFalse(imageTitles(payload).contains('Sibling photo GT7'), 'Sibling branch must not appear');
    }

    @IsTest
    static void shouldDescribeRecordsWithoutIds_WhenLoaded() {
        makeData();
        WorkOrder order = [SELECT Id, WorkOrderNumber FROM WorkOrder WHERE Subject = 'Gallery order GT7' LIMIT 1];
        Test.startTest();
        Map<String, Object> payload = load(order.Id);
        Test.stopTest();
        Boolean found = false;
        for (Object record : (List<Object>) payload.get('records')) {
            Map<String, Object> row = (Map<String, Object>) record;
            if (row.get('objectName') == 'WorkOrder') {
                found = true;
                Assert.areEqual(order.WorkOrderNumber, row.get('title'), 'Work order shows its number');
                Assert.areEqual('Gallery order GT7', ((String) row.get('subtitle')).substringBefore(' · '), 'Subject is the subtitle');
            }
        }
        Assert.isTrue(found, 'Work order record should be present');
    }

    private static List<Object> breadcrumbOf(Map<String, Object> payload, String objectName, String title) {
        for (Object item : (List<Object>) payload.get('records')) {
            Map<String, Object> rec = (Map<String, Object>) item;
            if (rec.get('objectName') == objectName && rec.get('title') == title) {
                Assert.isFalse(rec.containsKey('parentId') || rec.containsKey('assetId'), 'Breadcrumb lookup Ids are not sent to the client');
                return (List<Object>) rec.get('breadcrumb');
            }
        }
        Assert.fail('Record not found: ' + objectName + ' ' + title);
        return null;
    }

    @IsTest
    static void shouldBuildBreadcrumbs_WhenParentAssetAnchor() {
        makeData();
        Asset parent = [SELECT Id FROM Asset WHERE Name = 'Gallery Parent Asset GT7'];
        WorkOrder order = [SELECT WorkOrderNumber FROM WorkOrder WHERE Subject = 'Gallery order GT7' LIMIT 1];
        Test.startTest();
        Map<String, Object> payload = load(parent.Id);
        Test.stopTest();
        Assert.areEqual(0, breadcrumbOf(payload, 'Asset', 'Gallery Parent Asset GT7').size(), 'Anchor asset has no ancestors in context');
        List<Object> childTrail = breadcrumbOf(payload, 'Asset', 'Gallery Child Asset GT7');
        Assert.areEqual(1, childTrail.size(), 'Child asset sits under one asset');
        Assert.areEqual('Gallery Parent Asset GT7', childTrail[0], 'Child asset is under the parent asset');
        List<Object> orderTrail = breadcrumbOf(payload, 'WorkOrder', order.WorkOrderNumber);
        Assert.areEqual(1, orderTrail.size(), 'Work order sits under its asset');
        Assert.areEqual('Gallery Child Asset GT7', orderTrail[0], 'Work order is under its asset');
    }

    @IsTest
    static void shouldBuildBreadcrumbs_WhenParentWorkOrderExists() {
        makeData();
        WorkOrder parentOrder = [SELECT Id, AssetId, WorkOrderNumber FROM WorkOrder WHERE Subject = 'Gallery order GT7' LIMIT 1];
        WorkOrder childOrder = new WorkOrder(Subject = 'Gallery child order GT7', ParentWorkOrderId = parentOrder.Id, AssetId = parentOrder.AssetId);
        insert childOrder;
        childOrder = [SELECT WorkOrderNumber FROM WorkOrder WHERE Id = :childOrder.Id];
        Test.startTest();
        Map<String, Object> payload = load(parentOrder.Id);
        Test.stopTest();
        List<Object> trail = breadcrumbOf(payload, 'WorkOrder', childOrder.WorkOrderNumber);
        Assert.areEqual(2, trail.size(), 'Child order shows its asset and parent order');
        Assert.areEqual('Gallery Child Asset GT7', trail[0], 'Asset comes first');
        Assert.areEqual(parentOrder.WorkOrderNumber, trail[1], 'Parent order comes next');
    }

    private static Map<String, Object> recordOf(Map<String, Object> payload, String objectName) {
        for (Object item : (List<Object>) payload.get('records')) {
            Map<String, Object> rec = (Map<String, Object>) item;
            if (rec.get('objectName') == objectName) {
                return rec;
            }
        }
        Assert.fail('Record not found: ' + objectName);
        return null;
    }

    @IsTest
    static void shouldReturnPlacesAndStarts_WhenOrderHasCoordinatesAndAppointment() {
        makeData();
        WorkOrder order = [SELECT Id, AssetId FROM WorkOrder WHERE Subject = 'Gallery order GT7' LIMIT 1];
        order.Latitude = -37.8143;
        order.Longitude = 144.9718;
        update order;
        update new Asset(Id = order.AssetId, Latitude = -37.8200, Longitude = 144.9800);
        Datetime start = Datetime.newInstanceGmt(2026, 9, 15, 9, 0, 0);
        ServiceAppointment appointment = new ServiceAppointment(
            ParentRecordId = order.Id, SchedStartTime = start, SchedEndTime = start.addHours(1),
            EarliestStartTime = start.addDays(-1), DueDate = start.addDays(1), Latitude = -37.8150, Longitude = 144.9720
        );
        insert appointment;
        Test.startTest();
        Map<String, Object> payload = load(order.Id);
        Test.stopTest();
        Map<String, Object> orderRec = recordOf(payload, 'WorkOrder');
        Assert.areEqual(2, ((List<Object>) orderRec.get('places')).size(), 'Order checks against its own location and its asset');
        Assert.areEqual('2026-09-15T09:00:00Z', ((List<Object>) orderRec.get('starts'))[0], 'Order uses its appointment start');
        Assert.isFalse(orderRec.containsKey('lat') || orderRec.containsKey('schedStart'), 'Raw coordinates are not sent');
        Map<String, Object> appointmentRec = recordOf(payload, 'ServiceAppointment');
        Assert.areEqual(3, ((List<Object>) appointmentRec.get('places')).size(), 'Appointment checks own, order and asset locations');
        Assert.areEqual(1, ((List<Object>) appointmentRec.get('starts')).size(), 'Appointment uses only its own start');
    }

    @IsTest
    static void shouldLeavePlacesNull_WhenNoCoordinates() {
        makeData();
        WorkOrder order = [SELECT Id FROM WorkOrder WHERE Subject = 'Gallery order GT7' LIMIT 1];
        Test.startTest();
        Map<String, Object> payload = load(order.Id);
        Test.stopTest();
        Map<String, Object> orderRec = recordOf(payload, 'WorkOrder');
        Assert.isNull(orderRec.get('places'), 'No coordinates, nothing to check against');
        Assert.isNull(orderRec.get('starts'), 'No appointment, nothing to check against');
    }

    @IsTest
    static void shouldThrow_WhenRecordIdNull() {
        makeData();
        try {
            ImageGalleryController.getImages(null);
            Assert.fail('Expected AuraHandledException');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e.getMessage(), 'Message should be provided');
        }
    }

    @IsTest
    static void shouldReadGps_WhenJpegWithExif() {
        makeData();
        ContentVersion jpeg = [SELECT Id FROM ContentVersion WHERE Title = 'Order photo GT7'];
        Test.startTest();
        Map<String, Object> exif = (Map<String, Object>) JSON.deserializeUntyped(ImageGalleryController.getExif(new List<Id>{ jpeg.Id }));
        Test.stopTest();
        Map<String, Object> entry = (Map<String, Object>) exif.get(jpeg.Id);
        Assert.areEqual('ok', entry.get('s'), 'EXIF should be read');
        Assert.areEqual('2026-09-15T10:30:00', entry.get('t'), 'Capture time');
        Assert.areEqual(37.789722, (Decimal) entry.get('lat'), 'Latitude');
        Assert.areEqual(-122.396944, (Decimal) entry.get('lng'), 'Longitude');
    }

    @IsTest
    static void shouldSkip_WhenFileIsNotJpeg() {
        makeData();
        ContentVersion png = [SELECT Id FROM ContentVersion WHERE Title = 'Child asset photo GT7'];
        Test.startTest();
        Map<String, Object> exif = (Map<String, Object>) JSON.deserializeUntyped(ImageGalleryController.getExif(new List<Id>{ png.Id }));
        Test.stopTest();
        Assert.areEqual('skipped', ((Map<String, Object>) exif.get(png.Id)).get('s'), 'Non-JPEG is skipped');
    }

    @IsTest
    static void shouldUseRecordFields_WhenFileHasNoExif() {
        makeData();
        ContentVersion png = [SELECT Id FROM ContentVersion WHERE Title = 'Child asset photo GT7'];
        if (!Schema.SObjectType.ContentVersion.fields.getMap().containsKey('Capture_Time__c')) {
            return; // fields not present in this org
        }
        png.put('Capture_Time__c', Datetime.newInstanceGmt(2026, 9, 1, 8, 15, 0));
        png.put('Geolocation__Latitude__s', -33.8688);
        png.put('Geolocation__Longitude__s', 151.2093);
        update png;
        Test.startTest();
        Map<String, Object> exif = (Map<String, Object>) JSON.deserializeUntyped(ImageGalleryController.getExif(new List<Id>{ png.Id }));
        Test.stopTest();
        Map<String, Object> entry = (Map<String, Object>) exif.get(png.Id);
        Assert.areEqual('2026-09-01T08:15:00Z', entry.get('t'), 'Capture time comes from the record');
        Assert.areEqual('record', entry.get('tSrc'), 'Time source is the record');
        Assert.areEqual(-33.868800, (Decimal) entry.get('lat'), 'Latitude comes from the record');
        Assert.areEqual('record', entry.get('locSrc'), 'Location source is the record');
    }

    @IsTest
    static void shouldPreferExif_WhenBothPresent() {
        makeData();
        ContentVersion jpeg = [SELECT Id FROM ContentVersion WHERE Title = 'Order photo GT7'];
        if (!Schema.SObjectType.ContentVersion.fields.getMap().containsKey('Capture_Time__c')) {
            return;
        }
        jpeg.put('Capture_Time__c', Datetime.newInstanceGmt(2020, 1, 1, 0, 0, 0));
        jpeg.put('Geolocation__Latitude__s', 1);
        jpeg.put('Geolocation__Longitude__s', 1);
        update jpeg;
        Test.startTest();
        Map<String, Object> exif = (Map<String, Object>) JSON.deserializeUntyped(ImageGalleryController.getExif(new List<Id>{ jpeg.Id }));
        Test.stopTest();
        Map<String, Object> entry = (Map<String, Object>) exif.get(jpeg.Id);
        Assert.areEqual('2026-09-15T10:30:00', entry.get('t'), 'EXIF time wins');
        Assert.areEqual('exif', entry.get('locSrc'), 'EXIF location wins');
    }

    /** Reads a camera JPEG that already exists in the org (SeeAllData); skipped where the file is absent. */
    private static void assertLargeJpegGps(String title, Decimal lat, Decimal lng) {
        List<ContentVersion> files = [SELECT Id, ContentSize FROM ContentVersion WHERE Title = :title AND IsLatest = true LIMIT 1];
        if (files.isEmpty()) {
            return;
        }
        Assert.isTrue(files[0].ContentSize > 262144, 'Test file should be a large JPEG');
        Test.startTest();
        Map<String, Object> exif = (Map<String, Object>) JSON.deserializeUntyped(ImageGalleryController.getExif(new List<Id>{ files[0].Id }));
        Test.stopTest();
        Map<String, Object> entry = (Map<String, Object>) exif.get(files[0].Id);
        Assert.areEqual('ok', entry.get('s'), title + ' EXIF should be read');
        Assert.isNotNull(entry.get('t'), title + ' has a capture time');
        Assert.areEqual(lat, ((Decimal) entry.get('lat')).setScale(6), title + ' latitude');
        Assert.areEqual(lng, ((Decimal) entry.get('lng')).setScale(6), title + ' longitude');
        Assert.areEqual('exif', entry.get('locSrc'), title + ' location comes from EXIF');
    }

    @IsTest
    static void shouldReadGps_WhenLargeJpeg5MB() {
        assertLargeJpegGps('Downtown Melbourne', -37.814306, 144.971833);
    }

    @IsTest
    static void shouldReadGps_WhenLargeJpeg7MB() {
        assertLargeJpegGps('Racing in Philip Island', -38.506772, 145.230500);
    }

    @IsTest
    static void shouldReturnEmpty_WhenNoVersionIds() {
        makeData();
        Test.startTest();
        String result = ImageGalleryController.getExif(new List<Id>());
        Test.stopTest();
        Assert.areEqual('{}', result, 'Empty map');
    }
}
