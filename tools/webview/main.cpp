#include <cstdio>
#include <cstring>
#include <exception>
#include <string>

#include <webview/webview.h>

int main(int argc, char **argv) {
    constexpr char prefix[] = "http://127.0.0.1:";
    if (argc != 2 || std::strncmp(argv[1], prefix, sizeof(prefix) - 1) != 0) {
        std::fputs("Expected Codua's local UI address.\n", stderr);
        return 2;
    }

    try {
        webview::webview window(false, nullptr);
        window.set_title("Codua WebView").ensure_ok();
        window.set_size(460, 400, WEBVIEW_HINT_MIN).ensure_ok();
        window.set_size(960, 700, WEBVIEW_HINT_NONE).ensure_ok();
        const auto close_request = std::string("[\"") + argv[1] + "\"]";
        window.bind("coduaClose", [&](const std::string &request) -> std::string {
            if (request == close_request) window.terminate();
            return "null";
        }).ensure_ok();
        window.navigate(argv[1]).ensure_ok();
        window.run().ensure_ok();
    } catch (const std::exception &error) {
        std::fprintf(stderr, "Codua WebView: %s\n", error.what());
        return 1;
    }
    return 0;
}
