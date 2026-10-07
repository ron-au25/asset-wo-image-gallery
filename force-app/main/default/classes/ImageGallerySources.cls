/**
 * Static definitions of the record types shown in the image gallery, and the query engine that
 * reads them. Nothing is stored: no custom metadata, fields or objects. Fields that are missing
 * or not accessible are dropped at runtime, so an absent object never breaks the gallery.
 */
public with sharing class ImageGallerySources {
    /** One link from a source object to the gallery context (field IN set). */
    public class Filter {
        public String field;
        public String setName;
        public Filter(String field, String setName) {
            this.field = field;
            this.setName = setName;
        }
    }

    /** A record type that can carry images. */
    public class Source {
        public String objectName;
        public List<Filter> filters;
        public List<String> titleFields;
        public List<String> subtitleFields;
        public List<String> dateFields;
        /** Read in system mode (WorkPlan/WorkStep OWD is Private); files are still filtered by sharing. */
        public Boolean systemMode = false;
        /** Field holding the owning Work Order, whose address is the location fallback. */
        public String workOrderField;
        /** Field holding the parent record of the same type (Asset.ParentId, WorkOrder.ParentWorkOrderId), for breadcrumbs. */
        public String parentField;
        /** Field holding the related Asset, for breadcrumbs. */
        public String assetField;
        /** Reads Latitude/Longitude, so photos can be checked against this record's location. */
        public Boolean geo = false;
        /** Scheduled start field, so photos can be checked against the appointment time. */
        public String startField;
        public Source(String objectName, List<Filter> filters, List<String> titleFields, List<String> subtitleFields, List<String> dateFields) {
            this.objectName = objectName;
            this.filters = filters;
            this.titleFields = titleFields;
            this.subtitleFields = subtitleFields;
            this.dateFields = dateFields;
        }
    }

    /** A work location a photo is checked against. */
    public class Place {
        public String label;
        public Double lat;
        public Double lng;
        public Place(String label, Double lat, Double lng) {
            this.label = label;
            this.lat = lat;
            this.lng = lng;
        }
    }

    /** A record ready for display. The Id is for navigation only and is never shown. */
    public class Rec {
        public Id id;
        public String objectName;
        public String objectLabel;
        public String title;
        public String subtitle;
        public String dateLabel;
        public String dateValue;
        /** Owning Work Order's address, shown when a photo has no location of its own. */
        public String address;
        /** Names from the Asset down to this record's owner, e.g. Pump A, 00012929. Empty when unknown. */
        public List<String> breadcrumb;
        public transient Id workOrderId; // transient: never serialized to the LWC
        public transient Id parentId;
        public transient Id assetId;
        public transient Double lat;
        public transient Double lng;
        public transient String schedStart;
        /** Locations a photo on this record is checked against (own, owning Work Order, Asset). Null when none have coordinates. */
        public List<Place> places;
        /** Scheduled start times (ISO, GMT) of the relevant Service Appointments. Null when none. */
        public List<String> starts;
    }

    public static final String SET_ASSET = 'ASSET';
    public static final String SET_WO = 'WO';
    public static final String SET_WOLI = 'WOLI';
    public static final String SET_CASE = 'CASE';
    public static final String SET_WO_WOLI = 'WOWOLI';
    private static final List<String> ADDRESS_FIELDS = new List<String>{ 'Street', 'City', 'State', 'PostalCode', 'Country' };

    /** @return every source, in display order */
    public static List<Source> all() {
        Source workPlan = wo(new Source('WorkPlan', f('WorkOrderId', SET_WO), t('Name'), t(), t('CreatedDate')), 'WorkOrderId');
        workPlan.systemMode = true;
        Source workStep = wo(new Source('WorkStep', f('WorkOrderId', SET_WO), t('Name'), t('Status'), t('StartTime', 'CreatedDate')), 'WorkOrderId');
        workStep.systemMode = true;
        Source asset = new Source('Asset', f('Id', SET_ASSET), t('Name'), t('SerialNumber', 'Status'), t('InstallDate', 'CreatedDate'));
        asset.parentField = 'ParentId';
        asset.geo = true;
        Source workOrder = wo(new Source('WorkOrder', f('Id', SET_WO), t('WorkOrderNumber'), t('Subject', 'Status'), t('StartDate', 'CreatedDate')), 'Id');
        workOrder.parentField = 'ParentWorkOrderId';
        workOrder.assetField = 'AssetId';
        workOrder.geo = true;
        Source appointment = wo(new Source('ServiceAppointment', f('ParentRecordId', SET_WO_WOLI), t('AppointmentNumber'), t('Subject', 'Status'), t('ActualStartTime', 'SchedStartTime', 'CreatedDate')), 'ParentRecordId');
        appointment.parentField = 'ParentRecordId'; // a Work Order or a line item; resolved to the order for the time check
        appointment.geo = true;
        appointment.startField = 'SchedStartTime';
        Source caseSource = new Source('Case', f('Id', SET_CASE), t('CaseNumber'), t('Subject', 'Status'), t('CreatedDate'));
        caseSource.assetField = 'AssetId';
        Source measure = wo(new Source('Measure_Point__c', new List<Filter>{ new Filter('Asset__c', SET_ASSET), new Filter('Work_Order__c', SET_WO) },
            t('Component_Name__c', 'Name'), t('Measure_Type__c', 'Measure_Value__c', 'Defect_Location__c'), t('Update_Date__c', 'CreatedDate')), 'Work_Order__c');
        measure.assetField = 'Asset__c';
        Source parts = new Source('SDO_SCOM_Replacement_Parts__c', f('Asset__c', SET_ASSET), t('Name'), t(), t('CreatedDate'));
        parts.assetField = 'Asset__c';
        return new List<Source>{
            asset,
            workOrder,
            wo(new Source('WorkOrderLineItem', f('Id', SET_WOLI), t('LineItemNumber'), t('Subject', 'Status'), t('StartDate', 'CreatedDate')), 'WorkOrderId'),
            workPlan,
            workStep,
            appointment,
            caseSource,
            measure,
            wo(new Source('Work_Delay__c', f('Work_Order__c', SET_WO), t('Name__c', 'Name'), t('Delay_Reason__c'), t('Start_Date__c', 'CreatedDate')), 'Work_Order__c'),
            wo(new Source('Safety_Incident__c', f('Work_Order__c', SET_WO), t('Subject__c', 'Name'), t('Injury_Type__c', 'Status__c'), t('Incident_Date__c', 'CreatedDate')), 'Work_Order__c'),
            wo(new Source('Time_Report__c', f('Work_Order__c', SET_WO), t('Name'), t('Resource_Name__c', 'Status__c'), t('Start_Time__c', 'CreatedDate')), 'Work_Order__c'),
            wo(new Source('RS_PurchaseOrder__c', f('Work_Order__c', SET_WO), t('PO_Number__c', 'Name'), t('Supplier_Name__c', 'Status__c'), t('Document_Date__c', 'CreatedDate')), 'Work_Order__c'),
            parts
        };
    }

    /**
     * Sets each record's address to its owning Work Order's address (Street, City, State, PostalCode,
     * Country). Coordinates are not used. Inaccessible address fields are skipped.
     * @param records Records returned by fetch
     */
    public static void applyWorkOrderAddresses(List<Rec> records) {
        Set<Id> workOrderIds = new Set<Id>();
        for (Rec rec : records) {
            if (rec.workOrderId != null) {
                workOrderIds.add(rec.workOrderId);
            }
        }
        Map<String, Schema.SObjectField> fields = Schema.SObjectType.WorkOrder.fields.getMap();
        List<String> selected = new List<String>();
        for (String name : ADDRESS_FIELDS) {
            if (usable(fields, name)) {
                selected.add(name);
            }
        }
        if (workOrderIds.isEmpty() || selected.isEmpty()) {
            return;
        }
        Map<Id, String> addressById = new Map<Id, String>();
        for (SObject row : Database.queryWithBinds(
            'SELECT Id, ' + String.join(selected, ', ') + ' FROM WorkOrder WHERE Id IN :ids',
            new Map<String, Object>{ 'ids' => workOrderIds },
            AccessLevel.USER_MODE
        )) {
            String address = formatAddress(row, selected);
            if (address != null) {
                addressById.put(row.Id, address);
            }
        }
        for (Rec rec : records) {
            if (rec.workOrderId != null) {
                rec.address = addressById.get(rec.workOrderId);
            }
        }
    }

    private static String formatAddress(SObject row, List<String> selected) {
        List<String> parts = new List<String>();
        for (String name : selected) {
            String text = text(row, name);
            if (text != null) {
                parts.add(text.trim());
            }
        }
        return parts.isEmpty() ? null : String.join(parts, ', ');
    }

    private static Source wo(Source source, String field) {
        source.workOrderField = field;
        return source;
    }

    /**
     * Reads the records of one source that belong to the context.
     * @param source The source definition
     * @param sets Context Ids by set name
     * @param maxRows Row cap for this source
     * @return Display records; empty when the object/fields are unavailable
     */
    public static List<Rec> fetch(Source source, Map<String, Set<Id>> sets, Integer maxRows) {
        List<Rec> result = new List<Rec>();
        Schema.SObjectType type = Schema.getGlobalDescribe().get(source.objectName);
        if (type == null || maxRows <= 0) {
            return result;
        }
        Map<String, Schema.SObjectField> fields = type.getDescribe().fields.getMap();
        List<String> clauses = new List<String>();
        Map<String, Object> binds = new Map<String, Object>();
        for (Filter filter : source.filters) {
            Set<Id> ids = sets.get(filter.setName);
            if (ids != null && !ids.isEmpty() && usable(fields, filter.field)) {
                String bind = 'b' + clauses.size();
                clauses.add(filter.field + ' IN :' + bind);
                binds.put(bind, ids);
            }
        }
        if (clauses.isEmpty()) {
            return result;
        }
        List<String> selected = new List<String>{ 'Id', 'CreatedDate' };
        List<String> wanted = fieldNames(source);
        if (source.workOrderField != null) {
            wanted.add(source.workOrderField);
        }
        if (source.parentField != null) {
            wanted.add(source.parentField);
        }
        if (source.assetField != null) {
            wanted.add(source.assetField);
        }
        if (source.geo) {
            wanted.add('Latitude');
            wanted.add('Longitude');
        }
        if (source.startField != null) {
            wanted.add(source.startField);
        }
        for (String name : wanted) {
            if (usable(fields, name) && !selected.contains(name)) {
                selected.add(name);
            }
        }
        String soql = 'SELECT ' + String.join(selected, ', ') + ' FROM ' + source.objectName
            + ' WHERE ' + String.join(clauses, ' OR ') + ' ORDER BY CreatedDate DESC LIMIT ' + maxRows;
        List<SObject> rows = source.systemMode ? new SystemReader().query(soql, binds) : Database.queryWithBinds(soql, binds, AccessLevel.USER_MODE);
        for (SObject row : rows) {
            result.add(toRec(source, type, fields, row));
        }
        return result;
    }

    private static Rec toRec(Source source, Schema.SObjectType type, Map<String, Schema.SObjectField> fields, SObject row) {
        Rec rec = new Rec();
        rec.id = row.Id;
        rec.objectName = source.objectName;
        rec.objectLabel = type.getDescribe().getLabel();
        rec.title = firstText(row, source.titleFields) ?? rec.objectLabel;
        List<String> parts = new List<String>();
        for (String name : source.subtitleFields) {
            String text = text(row, name);
            if (text != null) {
                parts.add(text);
            }
        }
        rec.subtitle = parts.isEmpty() ? null : String.join(parts, ' · ');
        Object owner = source.workOrderField == null || !usable(fields, source.workOrderField) ? null : row.get(source.workOrderField);
        if (owner instanceof Id && ((Id) owner).getSObjectType() == WorkOrder.SObjectType) {
            rec.workOrderId = (Id) owner; // ServiceAppointment parents can be line items; those are skipped
        }
        rec.parentId = idValue(source.parentField, fields, row);
        rec.assetId = idValue(source.assetField, fields, row);
        if (source.geo) {
            rec.lat = doubleValue('Latitude', fields, row);
            rec.lng = doubleValue('Longitude', fields, row);
        }
        rec.schedStart = source.startField == null || !usable(fields, source.startField) ? null : text(row, source.startField);
        for (String name : source.dateFields) {
            String text = text(row, name);
            if (text != null && usable(fields, name)) {
                rec.dateLabel = fields.get(name.toLowerCase()).getDescribe().getLabel();
                rec.dateValue = text;
                break;
            }
        }
        return rec;
    }

    private static Double doubleValue(String name, Map<String, Schema.SObjectField> fields, SObject row) {
        return usable(fields, name) ? (Double) row.get(name) : null;
    }

    private static Id idValue(String name, Map<String, Schema.SObjectField> fields, SObject row) {
        return name == null || !usable(fields, name) ? null : (Id) row.get(name);
    }

    /**
     * Sets each record's breadcrumb: the Asset, any parent Work Orders and the owning Work Order,
     * by name or number. Only records inside the gallery's context are named, so ancestors above
     * the record the gallery was opened from are left out.
     * @param records Records returned by fetch
     */
    public static void applyBreadcrumbs(List<Rec> records) {
        Map<Id, Rec> byId = new Map<Id, Rec>();
        for (Rec rec : records) {
            if (rec.objectName == 'Asset' || rec.objectName == 'WorkOrder') {
                byId.put(rec.id, rec);
            }
        }
        for (Rec rec : records) {
            List<String> crumbs = new List<String>();
            if (rec.objectName == 'Asset') {
                crumbs.addAll(ancestors(rec.parentId, byId));
            } else if (rec.objectName == 'WorkOrder') {
                crumbs.addAll(workOrderTrail(rec.assetId, rec.parentId, byId));
            } else if (rec.workOrderId != null && byId.containsKey(rec.workOrderId)) {
                Rec owner = byId.get(rec.workOrderId);
                crumbs.addAll(workOrderTrail(owner.assetId, owner.parentId, byId));
                crumbs.add(owner.title);
            } else if (rec.assetId != null && byId.containsKey(rec.assetId)) {
                Rec owner = byId.get(rec.assetId);
                crumbs.addAll(ancestors(owner.parentId, byId));
                crumbs.add(owner.title);
            }
            rec.breadcrumb = crumbs;
        }
    }

    /**
     * Sets each record's places and appointment start times for the geofence and time-fence checks.
     * A record is checked against its own location, its Work Order's and its Asset's. Times come from
     * the appointment itself, or for any other record from the Service Appointments under the Work
     * Order or its line items. Records without coordinates or appointments are left null.
     * @param records Records returned by fetch
     */
    public static void applyFences(List<Rec> records) {
        Map<Id, Rec> byId = new Map<Id, Rec>();
        for (Rec rec : records) {
            byId.put(rec.id, rec);
        }
        Map<Id, List<String>> startsByOrder = new Map<Id, List<String>>();
        for (Rec rec : records) {
            Id orderId = orderOf(rec, byId)?.id;
            if (rec.schedStart != null && orderId != null) {
                if (!startsByOrder.containsKey(orderId)) {
                    startsByOrder.put(orderId, new List<String>());
                }
                startsByOrder.get(orderId).add(rec.schedStart);
            }
        }
        for (Rec rec : records) {
            Rec order = orderOf(rec, byId);
            List<Place> places = new List<Place>();
            addPlace(places, rec);
            if (order != null && order.id != rec.id) {
                addPlace(places, order);
            }
            Id assetId = rec.objectName == 'Asset' ? rec.id : (rec.assetId ?? order?.assetId);
            if (assetId != null && assetId != rec.id && byId.containsKey(assetId)) {
                addPlace(places, byId.get(assetId));
            }
            List<String> starts = new List<String>();
            if (rec.schedStart != null) {
                starts.add(rec.schedStart);
            } else if (order != null && startsByOrder.containsKey(order.id)) {
                starts.addAll(startsByOrder.get(order.id));
            }
            rec.places = places.isEmpty() ? null : places;
            rec.starts = starts.isEmpty() ? null : starts;
        }
    }

    /** The Work Order a record belongs to, directly or (for appointments) through a line item. */
    private static Rec orderOf(Rec rec, Map<Id, Rec> byId) {
        if (rec.workOrderId != null) {
            return byId.get(rec.workOrderId);
        }
        Rec parent = rec.schedStart == null || rec.parentId == null ? null : byId.get(rec.parentId);
        return parent?.workOrderId == null ? null : byId.get(parent.workOrderId);
    }

    private static void addPlace(List<Place> places, Rec rec) {
        if (rec.lat != null && rec.lng != null && !(rec.lat == 0 && rec.lng == 0)) {
            places.add(new Place(rec.objectLabel + ' ' + rec.title, rec.lat, rec.lng));
        }
    }

    private static List<String> workOrderTrail(Id assetId, Id parentId, Map<Id, Rec> byId) {
        List<String> trail = new List<String>();
        if (assetId != null && byId.containsKey(assetId)) {
            trail.add(byId.get(assetId).title);
        }
        trail.addAll(ancestors(parentId, byId));
        return trail;
    }

    /** Titles of the parent chain above a record, root first. Stops at the edge of the context or a cycle. */
    private static List<String> ancestors(Id parentId, Map<Id, Rec> byId) {
        List<String> trail = new List<String>();
        Set<Id> seen = new Set<Id>();
        Id next = parentId;
        while (next != null && byId.containsKey(next) && seen.add(next)) {
            Rec parent = byId.get(next);
            trail.add(parent.title);
            next = parent.parentId;
        }
        List<String> rootFirst = new List<String>();
        for (Integer i = trail.size() - 1; i >= 0; i--) {
            rootFirst.add(trail[i]);
        }
        return rootFirst;
    }

    private static String firstText(SObject row, List<String> names) {
        for (String name : names) {
            String text = text(row, name);
            if (text != null) {
                return text;
            }
        }
        return null;
    }

    private static String text(SObject row, String name) {
        Object value;
        try {
            value = row.get(name);
        } catch (Exception e) {
            return null; // field was not selected (unavailable)
        }
        if (value == null) {
            return null;
        }
        String text = value instanceof Datetime ? ((Datetime) value).formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') : String.valueOf(value);
        return String.isBlank(text) ? null : text;
    }

    private static Boolean usable(Map<String, Schema.SObjectField> fields, String name) {
        Schema.SObjectField field = fields.get(name.toLowerCase());
        return field != null && field.getDescribe().isAccessible();
    }

    private static List<String> fieldNames(Source source) {
        List<String> names = new List<String>();
        names.addAll(source.titleFields);
        names.addAll(source.subtitleFields);
        names.addAll(source.dateFields);
        return names;
    }

    private static List<Filter> f(String field, String setName) {
        return new List<Filter>{ new Filter(field, setName) };
    }

    private static List<String> t(String a, String b, String c) {
        return new List<String>{ a, b, c };
    }

    private static List<String> t(String a, String b) {
        return new List<String>{ a, b };
    }

    private static List<String> t(String a) {
        return new List<String>{ a };
    }

    private static List<String> t() {
        return new List<String>();
    }

    /**
     * System-mode reads for WorkPlan and WorkStep, whose OWD is Private. Only display text is
     * returned; image files are still filtered by the running user's sharing.
     */
    public without sharing class SystemReader {
        public List<SObject> query(String soql, Map<String, Object> binds) {
            return Database.queryWithBinds(soql, binds, AccessLevel.SYSTEM_MODE);
        }
    }
}
