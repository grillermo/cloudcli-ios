public enum ServerOriginShim {
    public static let source = #"""
    (function () {
      var server = 'https://claude.chiq.me';
      var socketServer = 'wss://claude.chiq.me';
      var prefixes = ['/api', '/ws', '/shell', '/plugin-ws'];

      function isServerPath(path) {
        return prefixes.some(function (p) {
          return path === p || path.indexOf(p + '/') === 0 || path.indexOf(p + '?') === 0;
        });
      }

      function appPath(url) {
        if (url.indexOf(location.origin) === 0) return url.slice(location.origin.length);
        return url;
      }

      function rewriteHttp(url) {
        if (typeof url !== 'string') return url;
        var path = appPath(url);
        return path.charAt(0) === '/' && isServerPath(path) ? server + path : url;
      }

      function rewriteSocket(url) {
        var match = /^wss?:\/\/app(\/.*)$/.exec(String(url));
        return match && isServerPath(match[1]) ? socketServer + match[1] : url;
      }

      var nativeFetch = window.fetch;
      window.fetch = function (input, init) {
        if (typeof Request !== 'undefined' && input instanceof Request) {
          var rewritten = rewriteHttp(input.url);
          return nativeFetch.call(window, rewritten === input.url ? input : new Request(rewritten, input), init);
        }
        return nativeFetch.call(window, rewriteHttp(typeof input === 'string' ? input : String(input)), init);
      };

      function wrapConstructor(name, rewrite) {
        window[name] = new Proxy(window[name], {
          construct: function (target, args) {
            args[0] = rewrite(args[0]);
            return Reflect.construct(target, args);
          }
        });
      }
      wrapConstructor('WebSocket', rewriteSocket);
      wrapConstructor('EventSource', rewriteHttp);

      var nativeOpen = window.XMLHttpRequest.prototype.open;
      window.XMLHttpRequest.prototype.open = function (method, url) {
        var args = Array.prototype.slice.call(arguments);
        args[1] = rewriteHttp(url);
        return nativeOpen.apply(this, args);
      };
    })();
    """#
}
