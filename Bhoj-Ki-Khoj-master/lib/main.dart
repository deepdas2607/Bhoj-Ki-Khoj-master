// ignore_for_file: library_private_types_in_public_api, unused_import, deprecated_member_use

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'firebase_options.dart';
import 'dart:convert';
import 'dart:io';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  await Permission.notification.request();
  await Permission.systemAlertWindow.request();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Color.fromRGBO(31, 126, 42, 1),
        statusBarIconBrightness: Brightness.light,
      ),
    );
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      home: WebviewScreen(),
    );
  }
}

class WebviewScreen extends StatefulWidget {
  const WebviewScreen({super.key});

  @override
  _WebviewScreenState createState() => _WebviewScreenState();
}

class _WebviewScreenState extends State<WebviewScreen> {
  // ignore: unused_field
  bool _isSplashDisplayed = true;
  bool isDarkMode = false;
  bool _isLoading = false;
  bool _isError = false;
  late final WebViewController _webViewController;
  DateTime? _lastBackPressed;

  @override
  void initState() {
    super.initState();
    _initializeWebView();
    _detectInitialTheme();
    _setupThemeListener();
    _addFirebaseAuthListener();

    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Color.fromRGBO(31, 126, 42, 1),
        statusBarIconBrightness: Brightness.light,
      ),
    );
  }

  @override
  void dispose() {
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Color.fromRGBO(31, 126, 42, 1),
        statusBarIconBrightness: Brightness.light,
      ),
    );
    super.dispose();
  }

  void _initializeWebView() {
    _webViewController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'flutterFetch',
        onMessageReceived: (JavaScriptMessage message) {
          fetchDataFromFlutter(message.message);
        },
      )
      ..addJavaScriptChannel(
        'flutterGoogleSignIn',
        onMessageReceived: (JavaScriptMessage message) async {
          await _handleGoogleSignIn();
        },
      )
      ..addJavaScriptChannel(
        'flutterAlert',
        onMessageReceived: (JavaScriptMessage message) {
          _showAlertDialog(context, message.message);
        },
      )
      ..addJavaScriptChannel(
        'flutterCloseApp',
        onMessageReceived: (JavaScriptMessage message) {
          _closeApp();
        },
      )
      ..addJavaScriptChannel(
        'flutterLoadExternalUrl',
        onMessageReceived: (JavaScriptMessage message) {
          _openExternalLink(message.message);
        },
      )
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (String url) {
          _applyThemeToWebView();
        },
        onWebResourceError: (WebResourceError error) {
          _loadOfflinePage();
          setState(() {
            _isError = true;
          });
        },
        onNavigationRequest: (NavigationRequest request) {
          if (request.url.startsWith('https:')) {
            _openExternalLink(request.url);
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
      ));

    _webViewController.loadRequest(Uri.parse(
        'file:///android_asset/flutter_assets/assets/pwa/splash.html'));

    _showSplashScreen();
  }

  Future<void> _showSplashScreen() async {
    await Future.delayed(const Duration(seconds: 8));
    setState(() {
      _isSplashDisplayed = false;
    });

    if (_isError != true) {
      _webViewController.loadRequest(Uri.parse(
          'file:///android_asset/flutter_assets/assets/pwa/index.html'));
    }
  }

  void _addFirebaseAuthListener() {
    FirebaseAuth.instance.authStateChanges().listen((User? user) {
      if (user != null) {
        _sendUserDataToWebView(user);
      }
    });
  }

  void _sendUserDataToWebView(User user) {
    String jsCode = '''
    var event = new CustomEvent('userSignedIn', { detail: ${jsonEncode(user)} });
    window.dispatchEvent(event);
    ''';
    _webViewController.runJavaScript(jsCode);
  }

  void _showAlertDialog(BuildContext context, String message) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Warning'),
          content: Text(message),
          actions: <Widget>[
            TextButton(
              child: const Text('OK'),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );
  }

  void _openExternalLink(String url) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ExternalWebviewScreen(url: url),
      ),
    );
  }

  Future<void> fetchDataFromFlutter(String filePath) async {
    try {
      String fileContent = await rootBundle.loadString('assets/pwa$filePath');
      final Map<String, dynamic> responseData = {
        'status': 200,
        'text': fileContent,
        'error': null,
      };

      String jsCode = '''
      var customEvent = new CustomEvent('flutterFetchResponse', {detail: ${jsonEncode(responseData)}});
      window.dispatchEvent(customEvent);
    ''';
      await _webViewController.runJavaScript(jsCode);
    } catch (e) {
      final Map<String, dynamic> errorResponse = {
        'status': 500,
        'text': '',
        'error': e.toString(),
      };

      String jsCode = '''
      var customEvent = new CustomEvent('flutterFetchResponse', {detail: ${jsonEncode(errorResponse)}});
      window.dispatchEvent(customEvent);
      window.flutterAlert.postMessage('Page will be resolved soon !!');
    ''';
      await _webViewController.runJavaScript(jsCode);
    }
  }

  Future<void> _handleGoogleSignIn() async {
    setState(() {
      _isLoading = true;
    });
    try {
      final GoogleSignInAccount? googleUser = await GoogleSignIn().signIn();
      final GoogleSignInAuthentication googleAuth =
          await googleUser!.authentication;

      // Create a new credential
      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      await FirebaseAuth.instance.signInWithCredential(credential);
      _sendUserDataToWebView(FirebaseAuth.instance.currentUser!);
    } catch (e) {
      String jsCode = '''
      var event = new CustomEvent('googleSignInError', { detail: ${jsonEncode({
            'error': e.toString()
          })} });
      window.dispatchEvent(event);
      ''';
      _webViewController.runJavaScript(jsCode);
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _loadOfflinePage() async {
    String htmlContent = await rootBundle.loadString('assets/pwa/offline.html');
    await _webViewController.loadRequest(Uri.dataFromString(
      htmlContent,
      mimeType: 'text/html',
      encoding: Encoding.getByName('utf-8'),
    ));
  }

  Future<void> _handlePopInvocation() async {
    String? currentUrl = await _webViewController.currentUrl();
    if (currentUrl != null &&
        currentUrl.contains('#!') &&
        !currentUrl.contains('/home/')) {
      if (await _webViewController.canGoBack()) {
        await _webViewController.goBack();
      }
    } else {
      DateTime now = DateTime.now();
      if (_lastBackPressed == null ||
          now.difference(_lastBackPressed!) > const Duration(seconds: 2)) {
        _lastBackPressed = now;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Press back again to exit')),
        );
      } else {
        _closeApp();
      }
    }
  }

  void _applyThemeToWebView() {
    String jsCode = """
      if (window.app && typeof window.app.setDarkMode === 'function') {
        if (${isDarkMode ? 'true' : 'false'}) {
          app.notification.create({ icon: '<i class="icon material-icons">warning</i>', title: 'App alert', subtitle: 'Dark mode is in devlopment',
            text: 'It may not work properly, so please use light mode',closeButton:true,}).open();
        }
        window.app.setDarkMode(${isDarkMode ? 'true' : 'false'});
      } else {
        console.warn('Dark mode function not available');
      }
    """;
    _webViewController.runJavaScript(jsCode);
  }

  void _detectInitialTheme() {
    final brightness =
        WidgetsBinding.instance.window.platformDispatcher.platformBrightness;
    isDarkMode = brightness == Brightness.dark;
    _applyThemeToWebView();
  }

  void _setupThemeListener() {
    WidgetsBinding
        .instance.window.platformDispatcher.onPlatformBrightnessChanged = () {
      final brightness =
          WidgetsBinding.instance.window.platformDispatcher.platformBrightness;
      setState(() {
        isDarkMode = brightness == Brightness.dark;
        _applyThemeToWebView();
      });
    };
  }

  void _closeApp() {
    if (Platform.isAndroid) {
      SystemNavigator.pop();
    } else if (Platform.isIOS) {
      exit(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) async {
        await _handlePopInvocation();
      },
      child: Scaffold(
        body: SafeArea(
          child: Stack(
            children: [
              WebViewWidget(controller: _webViewController),
              if (_isLoading)
                const Center(
                  child: CircularProgressIndicator(),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class ExternalWebviewScreen extends StatefulWidget {
  final String url;

  const ExternalWebviewScreen({super.key, required this.url});

  @override
  _ExternalWebviewScreenState createState() => _ExternalWebviewScreenState();
}

class _ExternalWebviewScreenState extends State<ExternalWebviewScreen> {
  late final WebViewController _externalWebViewController;

  @override
  void initState() {
    super.initState();
    _initializeExternalWebView();
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Color.fromRGBO(31, 126, 42, 1),
        statusBarIconBrightness: Brightness.light,
      ),
    );
  }

  @override
  void dispose() {
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Color.fromRGBO(31, 126, 42, 1),
        statusBarIconBrightness: Brightness.light,
      ),
    );
    super.dispose();
  }

  void _initializeExternalWebView() {
    _externalWebViewController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (String url) {
          // Handle when external page finishes loading
        },
        onWebResourceError: (WebResourceError error) {
          // Handle errors
        },
      ));

    _externalWebViewController.loadRequest(Uri.parse(widget.url));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(''),
        backgroundColor: Color.fromARGB(255, 31, 142, 42),
        foregroundColor: Colors.white,
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () {
            Navigator.pop(context);
          },
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () async {
              if (await _externalWebViewController.canGoBack()) {
                await _externalWebViewController.goBack();
              } else {
                Navigator.pop(context);
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              _externalWebViewController.reload();
            },
          ),
        ],
      ),
      body: SafeArea(
        child: WebViewWidget(controller: _externalWebViewController),
      ),
    );
  }
}
