use crate::error::{Result, ServiceError};

struct ParsedUrl<'a> {
    scheme: &'a str,
    host: &'a str,
    port: Option<u16>,
}

pub(crate) fn validate_http_url(value: &str) -> Result<()> {
    parse_http_url(value).map(|_| ())
}

pub(crate) fn require_same_origin(value: &str, request_host: &str) -> Result<()> {
    let origin = parse_http_url(value).map_err(|_| ServiceError::Forbidden)?;
    let (host, port) = parse_authority(request_host).ok_or(ServiceError::Forbidden)?;
    let same_host = origin.host.eq_ignore_ascii_case(host);
    let same_port = match (origin.port, port) {
        (Some(origin_port), Some(request_port)) => origin_port == request_port,
        (None, None) => true,
        (None, Some(80)) if origin.scheme == "http" => true,
        (None, Some(443)) if origin.scheme == "https" => true,
        _ => false,
    };

    if same_host && same_port {
        Ok(())
    } else {
        Err(ServiceError::Forbidden)
    }
}

fn parse_http_url(value: &str) -> Result<ParsedUrl<'_>> {
    let value = value.trim();
    let (scheme, rest) = value
        .split_once("://")
        .ok_or_else(|| ServiceError::BadRequest("URL must include a scheme".to_string()))?;
    if !matches!(scheme, "http" | "https") {
        return Err(ServiceError::BadRequest(
            "URL must use http or https".to_string(),
        ));
    }
    let authority = rest
        .split(['/', '?', '#'])
        .next()
        .filter(|authority| !authority.is_empty())
        .ok_or_else(|| ServiceError::BadRequest("URL must include a host".to_string()))?;
    let (host, port) = parse_authority(authority)
        .ok_or_else(|| ServiceError::BadRequest("URL host is invalid".to_string()))?;
    if host.trim().is_empty() || host.chars().any(char::is_whitespace) {
        return Err(ServiceError::BadRequest("URL host is invalid".to_string()));
    }

    Ok(ParsedUrl { scheme, host, port })
}

fn parse_authority(authority: &str) -> Option<(&str, Option<u16>)> {
    if authority.contains('@') {
        return None;
    }
    if let Some(rest) = authority.strip_prefix('[') {
        let (host, after_host) = rest.split_once(']')?;
        let port = if after_host.is_empty() {
            None
        } else {
            Some(after_host.strip_prefix(':')?.parse::<u16>().ok()?)
        };
        return Some((host, port));
    }
    if authority.matches(':').count() > 1 {
        return None;
    }

    match authority.rsplit_once(':') {
        Some((host, port)) if !port.is_empty() => Some((host, Some(port.parse::<u16>().ok()?))),
        Some((host, _)) => Some((host, None)),
        None => Some((authority, None)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validates_http_urls() {
        assert!(validate_http_url("https://api.example.com/v1").is_ok());
        assert!(validate_http_url("file:///tmp/token").is_err());
        assert!(validate_http_url("https://").is_err());
    }

    #[test]
    fn compares_same_origin_with_port() {
        assert!(require_same_origin("http://localhost:4098/app", "localhost:4098").is_ok());
        assert!(require_same_origin("http://localhost:4097/app", "localhost:4098").is_err());
    }
}
