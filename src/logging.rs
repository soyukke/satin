use std::{
    env,
    io::{self, Write},
    sync::Once,
};

use log::{LevelFilter, Log, Metadata, Record};

static INIT: Once = Once::new();
static LOGGER: NativeLogger = NativeLogger;

pub fn init() {
    INIT.call_once(|| {
        let level = match env::var("SATIN_LOG")
            .or_else(|_| env::var("NVTERM_LOG"))
            .unwrap_or_else(|_| "info".to_owned())
            .to_ascii_lowercase()
            .as_str()
        {
            "off" => LevelFilter::Off,
            "error" => LevelFilter::Error,
            "warn" => LevelFilter::Warn,
            "debug" => LevelFilter::Debug,
            "trace" => LevelFilter::Trace,
            _ => LevelFilter::Info,
        };
        if log::set_logger(&LOGGER).is_ok() {
            log::set_max_level(level);
        }
    });
}

struct NativeLogger;

impl Log for NativeLogger {
    fn enabled(&self, metadata: &Metadata<'_>) -> bool {
        metadata.level() <= log::max_level()
    }

    fn log(&self, record: &Record<'_>) {
        if !self.enabled(record.metadata()) {
            return;
        }
        let mut stderr = io::stderr().lock();
        let _ = writeln!(
            stderr,
            "level={} target={} message={}",
            record.level().as_str().to_ascii_lowercase(),
            record.target(),
            record.args()
        );
    }

    fn flush(&self) {
        let _ = io::stderr().flush();
    }
}
