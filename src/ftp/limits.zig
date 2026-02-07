/// Maximum size of a single FTP command line, including CRLF.
pub const command_max: usize = 1024;
/// Maximum size of a single control reply line.
pub const reply_max: usize = 1024;
/// Size of the streaming data transfer buffer.
pub const transfer_max: usize = 4096;
/// Size of the scratch buffer for formatting and parsing.
pub const scratch_max: usize = 2048;
