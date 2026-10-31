import Darwin
import Foundation

/// Byte transport to a board. `SerialPort` is the real one; tests substitute a fake device.
public protocol DeviceTransport: AnyObject, Sendable {
    /// Called on a background queue with every chunk read from the device.
    var onData: (@Sendable (Data) -> Void)? { get set }
    /// Called once if the device goes away (unplugged, reset over USB).
    var onClose: (@Sendable () -> Void)? { get set }
    func write(_ data: Data) throws
    func close()
}

public enum SerialError: LocalizedError {
    case open(String, Int32)
    case configure(Int32)
    case write(Int32)
    case closed

    public var errorDescription: String? {
        switch self {
        case let .open(path, code) where code == EBUSY:
            "\(path) is in use by another program (mpremote, Thonny, a serial monitor?)"
        case let .open(path, code): "Cannot open \(path): \(String(cString: strerror(code)))"
        case let .configure(code): "Cannot configure the serial port: \(String(cString: strerror(code)))"
        case let .write(code): "Serial write failed: \(String(cString: strerror(code)))"
        case .closed: "The serial port is closed"
        }
    }
}

/// A POSIX serial port (`/dev/cu.*`) in raw 8N1 mode, opened exclusively so a second program
/// can't interleave bytes with ours.
public final class SerialPort: DeviceTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32
    private var source: DispatchSourceRead?
    private var _onData: (@Sendable (Data) -> Void)?
    private var _onClose: (@Sendable () -> Void)?
    public let path: String

    public var onData: (@Sendable (Data) -> Void)? {
        get { lock.withLock { _onData } }
        set { lock.withLock { _onData = newValue } }
    }

    public var onClose: (@Sendable () -> Void)? {
        get { lock.withLock { _onClose } }
        set { lock.withLock { _onClose = newValue } }
    }

    public init(path: String, baudRate: Int = 115_200) throws {
        self.path = path
        // O_NONBLOCK: don't wait for carrier detect; cleared again below.
        fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw SerialError.open(path, errno) }
        do {
            if ioctl(fd, TIOCEXCL) != 0 || flock(fd, LOCK_EX | LOCK_NB) != 0 {
                throw SerialError.open(path, EBUSY)
            }
            try configure(baudRate: baudRate)
        } catch {
            Darwin.close(fd)
            throw error
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "serial.read"))
        source.setEventHandler { [weak self] in self?.readAvailable() }
        self.source = source
        source.resume()
    }

    deinit { close() }

    private func configure(baudRate: Int) throws {
        var options = termios()
        guard tcgetattr(fd, &options) == 0 else { throw SerialError.configure(errno) }
        cfmakeraw(&options)
        options.c_cflag |= tcflag_t(CLOCAL | CREAD)
        options.c_cflag &= ~tcflag_t(CRTSCTS | CSTOPB | PARENB)
        options.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
        cfsetispeed(&options, speed_t(baudRate))
        cfsetospeed(&options, speed_t(baudRate))
        guard tcsetattr(fd, TCSANOW, &options) == 0 else { throw SerialError.configure(errno) }
        // Back to blocking writes (reads are driven by the dispatch source).
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        tcflush(fd, TCIOFLUSH)
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let fd = lock.withLock { self.fd }
        guard fd >= 0 else { return }
        let count = Darwin.read(fd, &buffer, buffer.count)
        if count > 0 {
            onData?(Data(buffer[0..<count]))
        } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
            // EOF or ENXIO: the USB device disappeared.
            let handler = onClose
            close()
            handler?()
        }
    }

    public func write(_ data: Data) throws {
        let fd = lock.withLock { self.fd }
        guard fd >= 0 else { throw SerialError.closed }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    throw SerialError.write(errno)
                }
                offset += n
            }
        }
    }

    public func close() {
        let (fd, source) = lock.withLock {
            let pair = (self.fd, self.source)
            self.fd = -1
            self.source = nil
            return pair
        }
        guard fd >= 0 else { return }
        source?.cancel()
        flock(fd, LOCK_UN)
        Darwin.close(fd)
    }

    /// USB serial ports that may be a board, e.g. `/dev/cu.usbserial-110` (CH340), `cu.SLAB_USBtoUART`
    /// (CP210x) or `cu.usbmodem…` (native USB on S2/S3/C3).
    public static func availablePorts() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return names
            .filter { $0.hasPrefix("cu.") && isLikelyBoard($0) }
            .sorted()
            .map { "/dev/" + $0 }
    }

    static func isLikelyBoard(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["usbserial", "usbmodem", "slab_usbtouart", "wchusbserial"].contains { lower.contains($0) }
    }
}
