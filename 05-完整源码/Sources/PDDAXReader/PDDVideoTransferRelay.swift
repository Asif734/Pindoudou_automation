import Foundation

actor PDDVideoTransferRelay {
    typealias Handler = @Sendable (PDDVideoTransferEvent) async -> Void

    private var buffered: [PDDVideoTransferEvent] = []
    private var handler: Handler?

    func send(_ event: PDDVideoTransferEvent) async {
        guard let handler else {
            buffered.append(event)
            return
        }
        await handler(event)
    }

    func install(_ handler: @escaping Handler) async {
        self.handler = handler
        let pending = buffered
        buffered.removeAll()
        for event in pending {
            await handler(event)
        }
    }
}
