use tokio::io::{AsyncRead, AsyncWrite};

/// A duplex byte stream we can talk Modbus over, whether TCP or serial.
pub trait AsyncStream: AsyncRead + AsyncWrite + Unpin + Send {}
impl<T: AsyncRead + AsyncWrite + Unpin + Send> AsyncStream for T {}

pub type BoxStream = Box<dyn AsyncStream>;
