import boto3
import gzip
import os
from io import BytesIO
from datetime import datetime, timedelta

# 時間範囲の設定 - 実行間隔：1時間
TIME_WINDOW = {
    'FROM_HOURS_AGO': 2,      # 2時間前から
    'TO_HOURS_AGO': 1,        # 1時間前まで
    'BUFFER_MINUTES': 10      # 10分のバッファ
}

def lambda_handler(event, context):
    rds_client = boto3.client('rds')
    s3_client = boto3.client('s3')
    
    # 環境変数
    rds_prefix = os.environ['RDS_PREFIX']
    s3_bucket = os.environ['S3_BUCKET']
    transfer_audit_logs = os.getenv('TRANSFER_AUDIT_LOGS', 'false').lower() == 'true'
    transfer_error_logs = os.getenv('TRANSFER_ERROR_LOGS', 'false').lower() == 'true'
    transfer_slow_query_logs = os.getenv('TRANSFER_SLOW_QUERY_LOGS', 'false').lower() == 'true'

    # 時間範囲の計算
    now = datetime.now()
    from_time = now - timedelta(hours=TIME_WINDOW['FROM_HOURS_AGO'], 
                              minutes=TIME_WINDOW['BUFFER_MINUTES'])
    to_time = now - timedelta(hours=TIME_WINDOW['TO_HOURS_AGO'])
    
    # Unixタイムスタンプ（ミリ秒）に変換
    from_time_ts = int(from_time.timestamp() * 1000)
    to_time_ts = int(to_time.timestamp() * 1000)
    
    print(f"Log collection period:")
    print(f"- From: {from_time.isoformat()} ({TIME_WINDOW['FROM_HOURS_AGO']} hours ago)")
    print(f"- To: {to_time.isoformat()} ({TIME_WINDOW['TO_HOURS_AGO']} hour ago)")
    print(f"Settings - Error Logs: {transfer_error_logs}, Slow Query Logs: {transfer_slow_query_logs}, Audit Logs: {transfer_audit_logs}")

    total_records = 0
    processed_files = 0
    
    instances = rds_client.describe_db_instances()
    for instance in instances['DBInstances']:
        if instance['DBInstanceIdentifier'].startswith(rds_prefix):
            instance_name = instance['DBInstanceIdentifier']
            print(f"\nProcessing instance: {instance_name}")
            
            instance_records = 0
            instance_files = 0

            try:
                # ページング処理を使用してすべてのログファイルを取得
                marker = '0'
                all_log_files = []
                
                while True:
                    logs = rds_client.describe_db_log_files(
                        DBInstanceIdentifier=instance_name,
                        FileLastWritten=from_time_ts,
                        MaxRecords=256,
                        Marker=marker
                    )
                    
                    all_log_files.extend(logs['DescribeDBLogFiles'])
                    
                    if 'Marker' not in logs or not logs['Marker']:
                        break
                        
                    marker = logs['Marker']
                
                print(f"\nFound total {len(all_log_files)} log files")
                print("\nAvailable log files:")
                for log in all_log_files:
                    print(f"- {log['LogFileName']} (Last Written: {datetime.fromtimestamp(log['LastWritten']/1000).isoformat()})")
            except Exception as e:
                print(f"Error getting log files: {str(e)}")
                continue

            print("\nProcessing log files:")
            for log in all_log_files:
                log_file_name = log['LogFileName'].lower()
                last_written = datetime.fromtimestamp(log['LastWritten']/1000)
                
                is_audit = "audit" in log_file_name
                is_error = "error" in log_file_name
                is_slow = any(pattern in log_file_name for pattern in ['slowquery', 'slow-query', 'slow_query', 'slow/'])
                
                print(f"\nFile: {log['LogFileName']}")
                print(f"- Last written: {last_written.isoformat()}")
                print(f"- Is audit log: {is_audit}")
                print(f"- Is error log: {is_error}")
                print(f"- Is slow query log: {is_slow}")
                
                # 時間範囲の判定
                if from_time_ts <= log['LastWritten'] < to_time_ts:
                    object_key = f"rds/{instance_name}/{log['LogFileName']}.gz"
                    
                    should_process = (
                        (is_audit and transfer_audit_logs) or
                        (is_error and transfer_error_logs) or
                        (is_slow and transfer_slow_query_logs)
                    )
                    
                    if should_process:
                        try:
                            all_data = []
                            log_marker = '0'
                            
                            # ログファイルの内容をページングで取得
                            while True:
                                log_data = rds_client.download_db_log_file_portion(
                                    DBInstanceIdentifier=instance_name,
                                    LogFileName=log['LogFileName'],
                                    Marker=log_marker
                                )
                                
                                if log_data.get('LogFileData'):
                                    all_data.append(log_data['LogFileData'])
                                
                                if not log_data.get('AdditionalDataPending', False):
                                    break
                                    
                                log_marker = log_data['Marker']
                            
                            if not all_data:
                                print(f"No data in log file: {log['LogFileName']}")
                                continue

                            # 取得したデータを結合
                            complete_log_data = ''.join(all_data)
                            record_count = len(complete_log_data.splitlines())
                            
                            compressed_data = BytesIO()
                            with gzip.GzipFile(fileobj=compressed_data, mode='wb') as f:
                                f.write(complete_log_data.encode('utf-8'))
                            compressed_data.seek(0)
                            
                            s3_client.upload_fileobj(
                                Fileobj=compressed_data,
                                Bucket=s3_bucket,
                                Key=object_key
                            )

                            instance_records += record_count
                            instance_files += 1
                            print(f"Processed {log['LogFileName']}: {record_count} records")
                        except Exception as e:
                            print(f"Error processing {log['LogFileName']}: {str(e)}")
                    else:
                        print(f"Skipping file (not matching enabled log types)")
                else:
                    print(f"Skipping file (outside time window {from_time.isoformat()} to {to_time.isoformat()})")

            if instance_files > 0:
                print(f"\nInstance {instance_name} summary - Files: {instance_files}, Records: {instance_records}")
            total_records += instance_records
            processed_files += instance_files

    print(f"\nExecution complete - Total files: {processed_files}, Total records: {total_records}")
    return {
        'statusCode': 200,
        'body': f'Log file processing completed. Processed {processed_files} files with {total_records} records.'
    }