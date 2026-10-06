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

    @IsTest
    static void shouldReturnEmpty_WhenNoVersionIds() {
        makeData();
        Test.startTest();
        String result = ImageGalleryController.getExif(new List<Id>());
        Test.stopTest();
        Assert.areEqual('{}', result, 'Empty map');
    }
}
