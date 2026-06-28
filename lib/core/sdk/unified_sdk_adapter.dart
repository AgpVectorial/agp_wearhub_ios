import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'sdk_provider.dart';
import 'qc_sdk_service.dart';

// ------------------------------------------
//  Provider � SDK unic (QC Wireless)
// ------------------------------------------

final unifiedSdkServiceProvider = Provider<SdkService>((ref) {
  return QcSdkService();
});
