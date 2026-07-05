const std = @import("std");

pub const RegistrationStatus = enum {
    vigente,
    renovacion,
    vencido,
    otro,

    pub fn datasetId(self: RegistrationStatus) []const u8 {
        return switch (self) {
            .vigente => "i7cb-raxc",
            .renovacion => "vgr4-gemg",
            .vencido => "vwwf-4ftk",
            .otro => "spzp-dfuc",
        };
    }

    pub fn parse(value: []const u8) ?RegistrationStatus {
        if (std.ascii.eqlIgnoreCase(value, "vigente")) return .vigente;
        if (std.ascii.eqlIgnoreCase(value, "renovacion") or std.ascii.eqlIgnoreCase(value, "renovación")) return .renovacion;
        if (std.ascii.eqlIgnoreCase(value, "vencido")) return .vencido;
        if (std.ascii.eqlIgnoreCase(value, "otro") or std.ascii.eqlIgnoreCase(value, "otros")) return .otro;
        return null;
    }

    pub fn toString(self: RegistrationStatus) []const u8 {
        return switch (self) {
            .vigente => "vigente",
            .renovacion => "renovacion",
            .vencido => "vencido",
            .otro => "otro",
        };
    }
};

pub const Medicine = struct {
    expediente: ?[]const u8 = null,
    producto: ?[]const u8 = null,
    titular: ?[]const u8 = null,
    registrosanitario: ?[]const u8 = null,
    fechaexpedicion: ?[]const u8 = null,
    fechavencimiento: ?[]const u8 = null,
    estadoregistro: ?[]const u8 = null,
    expedientecum: ?[]const u8 = null,
    consecutivocum: ?[]const u8 = null,
    cantidadcum: ?[]const u8 = null,
    descripcioncomercial: ?[]const u8 = null,
    estadocum: ?[]const u8 = null,
    fechaactivo: ?[]const u8 = null,
    fechainactivo: ?[]const u8 = null,
    muestramedica: ?[]const u8 = null,
    unidad: ?[]const u8 = null,
    atc: ?[]const u8 = null,
    descripcionatc: ?[]const u8 = null,
    viaadministracion: ?[]const u8 = null,
    concentracion: ?[]const u8 = null,
    principioactivo: ?[]const u8 = null,
    unidadmedida: ?[]const u8 = null,
    cantidad: ?std.json.Value = null,
    unidadreferencia: ?[]const u8 = null,
    formafarmaceutica: ?[]const u8 = null,
    nombrerol: ?[]const u8 = null,
    tiporol: ?[]const u8 = null,
    modalidad: ?[]const u8 = null,
    ium: ?[]const u8 = null,
};

pub const MedicineSuggestion = struct {
    expediente: ?[]const u8 = null,
    producto: ?[]const u8 = null,
    titular: ?[]const u8 = null,
    registrosanitario: ?[]const u8 = null,
    consecutivocum: ?[]const u8 = null,
    cantidadcum: ?[]const u8 = null,
    descripcioncomercial: ?[]const u8 = null,
    atc: ?[]const u8 = null,
    nombrerol: ?[]const u8 = null,
    muestramedica: ?[]const u8 = null,
};

pub const TramitePaso = struct {
    orden_paso: ?[]const u8 = null,
    descripcion_paso: ?[]const u8 = null,
    orden_condicion: ?[]const u8 = null,
    tipo_accion_condicion: ?[]const u8 = null,
    documento_nombre: ?[]const u8 = null,
    documento_tipo: ?[]const u8 = null,
    descripcion_del_pago: ?[]const u8 = null,
};

pub const TramiteSuit = struct {
    numero_unico: ?[]const u8 = null,
    nombre_tramite: ?[]const u8 = null,
    nombre_comun: ?[]const u8 = null,
    proposito: ?[]const u8 = null,
    nombre_resultado: ?[]const u8 = null,
    clase: ?[]const u8 = null,
    entidad: []const u8,
    fecha_actualizacion: ?[]const u8 = null,
    categorias: [][]const u8 = &.{},
    pasos: []TramitePaso = &.{},
};

pub const TramiteSearchResult = struct {
    total: usize,
    limit: usize,
    offset: usize,
    tramites: []TramiteSuit,
};
