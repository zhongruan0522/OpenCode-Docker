use axum::{http::header, response::Html};

pub(crate) async fn index() -> Html<&'static str> {
    Html(include_str!("../../../frontend/manager/index.html"))
}

pub(crate) async fn script() -> impl axum::response::IntoResponse {
    ([
        (header::CONTENT_TYPE, "application/javascript; charset=utf-8"),
        (header::CACHE_CONTROL, "no-store"),
    ], include_str!("../../../frontend/manager/app.js"))
}

pub(crate) async fn styles() -> impl axum::response::IntoResponse {
    ([
        (header::CONTENT_TYPE, "text/css; charset=utf-8"),
        (header::CACHE_CONTROL, "no-store"),
    ], include_str!("../../../frontend/manager/styles.css"))
}
