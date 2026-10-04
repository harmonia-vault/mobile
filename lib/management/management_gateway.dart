import 'management_presentation.dart';

const managementOperations = {
  'managementDevices',
  'prepareDeviceGrant',
  'prepareOtherDeviceRevocation',
  'managementInfo',
  'retryManagement',
  'cancelManagement',
};

abstract interface class DeviceManagementGateway {
  Set<String> get managementCapabilities;
  ManagementOperation get managementOperation;
  Future<ManagementOperation> inspectManagement();
  Future<List<ManagedDeviceAccess>> managementDevices(String environmentId);
  Future<ManagementOperation> prepareDeviceGrant({
    required String environmentId,
    required String subjectDeviceId,
    required ManagedRole role,
    required ManagementExpiry expiry,
  });
  Future<ManagementOperation> prepareOtherDeviceRevocation({
    required String environmentId,
    required String subjectDeviceId,
  });
  Future<ManagementOperation> retryManagement(String originalId);
  Future<ManagementOperation> cancelManagement(String originalId);

  /// 只清Dart显示/退役旧结果，不删除原生原包。
  void retireManagementResults();
}
