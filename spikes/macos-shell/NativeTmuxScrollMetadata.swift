extension RustTmuxPane {
    @discardableResult
    func prepareHydration() -> Bool {
        satinRuntimeTmuxPrepareHydration(handle) != 0
    }

    @discardableResult
    func recordScrollMetadata(
        rows: Int,
        regionTop: UInt16?,
        regionBottom: UInt16?,
        regionLeft: UInt16?,
        regionRight: UInt16?
    ) -> Bool {
        satinRuntimeTmuxRecordScrollMetadata(
            handle,
            rows,
            regionTop ?? 0,
            regionBottom ?? 0,
            regionLeft ?? 0,
            regionRight ?? 0
        ) != 0
    }
}
