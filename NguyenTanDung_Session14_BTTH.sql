use homework_ss14;

-- PHẦN A: PHÂN TÍCH & THIẾT KẾ
-- 1. PHÂN TÍCH I/O
-- tham số đầu vào (in):
--   p_patient_id  int           : mã bệnh nhân
--   p_product_id  int           : mã sản phẩm (thiết bị y tế)
--   p_quantity    int           : số lượng mua
-- tham số đầu ra (out):
--   p_message     varchar(255)  : chuỗi thông báo trạng thái trả về
--
-- lý do dùng OUT thay vì IN/INOUT:
--   - out: thủ tục chỉ ghi giá trị ra ngoài, không đọc giá trị đầu vào -> phù hợp
--     vì p_message chỉ dùng để trả thông báo về cho caller.
--   - inout: dùng khi cần đọc giá trị cũ rồi ghi đè giá trị mới -> không cần ở đây.
--   -> chọn OUT là đúng.

-- 2. THIẾT KẾ LUỒNG (PSEUDOCODE)
-- begin transaction
--   [kiểm tra 1] lấy stock của product -> nếu p_quantity > stock thì
--                rollback + set p_message = 'thất bại: kho không đủ cần phẩm' + exit
--   [kiểm tra 2] tính thanh_tien = p_quantity * price
--                lấy balance của wallet -> nếu thanh_tien > balance thì
--                rollback + set p_message = 'thất bại: số dư ví không đủ' + exit
--   [kiểm tra 3] lấy status của wallet -> nếu status = 'inactive' thì
--                rollback + set p_message = 'thất bại: ví đang bị khóa' + exit
--   [thao tác 1] update products: stock = stock - p_quantity
--   [thao tác 2] update wallets:  balance = balance - thanh_tien
-- commit
-- set p_message = 'thành công: đã xử lý đơn hàng'

-- biến cục bộ cần khai báo:
--   v_stock      int            : tồn kho hiện tại của sản phẩm
--   v_price      decimal(18,2)  : đơn giá sản phẩm
--   v_balance    decimal(18,2)  : số dư ví bệnh nhân
--   v_status     varchar(20)    : trạng thái ví
--   v_total      decimal(18,2)  : thành tiền = p_quantity * v_price
-- vị trí đặt lệnh kiểm soát giao dịch:
--   start transaction -> ngay đầu phần xử lý (sau khai báo biến)
--   rollback          -> ngay trước mỗi signal lỗi
--   commit            -> sau khi tất cả update thành công


-- PHẦN B: TRIỂN KHAI CODE VÀ KIỂM THỬ
drop procedure if exists process_equipment_purchase;

delimiter //

create procedure process_equipment_purchase(
    in  p_patient_id  int,
    in  p_product_id  int,
    in  p_quantity    int,
    out p_message     varchar(255)
)
begin
    -- khai báo biến cục bộ
    declare v_stock    int            default 0;
    declare v_price    decimal(18,2)  default 0;
    declare v_balance  decimal(18,2)  default 0;
    declare v_status   varchar(20)    default '';
    declare v_total    decimal(18,2)  default 0;

    -- handler bắt mọi lỗi sql không lường trước
    declare exit handler for sqlexception
    begin
        rollback;
        set p_message = 'thất bại: lỗi hệ thống, giao dịch đã bị hủy';
    end;

    -- bắt đầu giao dịch
    start transaction;

    -- [kiểm tra 1] tồn kho sản phẩm
    select price, stock
    into   v_price, v_stock
    from   products
    where  product_id = p_product_id
    for update;

    if p_quantity > v_stock then
        rollback;
        set p_message = 'thất bại: kho không đủ cần phẩm';
        leave process_equipment_purchase;  -- thoát khỏi thủ tục ngay lập tức
    end if;

    -- [kiểm tra 2 & 3] ví điện tử thực hiện cùng 1 lần select để tối ưu
    select balance, status
    into   v_balance, v_status
    from   wallets
    where  patient_id = p_patient_id
    for update;

    -- kiểm tra ví bị khóa trước, ưu tiên thông báo rõ ràng hơn
    if v_status = 'inactive' then
        rollback;
        set p_message = 'thất bại: ví đang bị khóa';
        leave process_equipment_purchase;
    end if;

    -- tính thành tiền
    set v_total = p_quantity * v_price;

    -- kiểm tra số dư
    if v_total > v_balance then
        rollback;
        set p_message = 'thất bại: số dư ví không đủ';
        leave process_equipment_purchase;
    end if;

    -- [thao tác 1] trừ tồn kho sản phẩm
    update products
    set    stock = stock - p_quantity
    where  product_id = p_product_id;

    -- [thao tác 2] trừ tiền trong ví bệnh nhân
    update wallets
    set    balance = balance - v_total
    where  patient_id = p_patient_id;

    -- tất cả thành công -> commit
    commit;
    set p_message = 'thành công: đã xử lý đơn hàng';

end //

delimiter ;

-- KIỂM THỬ 4 KỊCH BẢN
-- xem trạng thái dữ liệu trước khi test
select 'du lieu truoc khi test' as ghi_chu;
select product_id, name, price, stock from products;
select patient_id, balance, status from wallets;
-- test 1: mua hàng hợp lệ
-- bệnh nhân 1 (ví active, balance=500,000) mua 1 máy đo huyết áp (product_id=1, giá=850,000)
-- -> thất bại vì 850,000 > 500,000
-- -> đổi: mua máy đo đường huyết (product_id=2, giá=450,000, stock=15)
-- kết quả mong đợi: thành công -> balance còn 50,000 | stock còn 14
set @msg1 = '';
call processequipmentpurchase(1, 2, 1, @msg1);
select 'test case 1 - mua hang hop le' as ten_test, @msg1 as thong_bao;
select patient_id, balance as so_du_sau from wallets where patient_id = 1;
select product_id, name, stock as ton_kho_sau from products where product_id = 2;

-- test 2: lỗi out of stock
-- mua 100 máy đo huyết áp (product_id=1, stock=20) -> số lượng 100 > stock 20
-- kết quả mong đợi: thất bại: kho không đủ cần phẩm | stock không đổi
set @msg2 = '';
call processequipmentpurchase(1, 1, 100, @msg2);
select 'test case 2 - out of stock' as ten_test, @msg2 as thong_bao;
select product_id, name, stock as ton_kho_khong_doi from products where product_id = 1;

-- test 3: lỗi insufficient funds (cháy ví)
-- bệnh nhân 2 (ví active, balance=50,000) mua 1 máy đo huyết áp (giá=850,000)
-- kết quả mong đợi: thất bại: số dư ví không đủ | balance không đổi
set @msg3 = '';
call processequipmentpurchase(2, 1, 1, @msg3);
select 'test case 3 - insufficient funds' as ten_test, @msg3 as thong_bao;
select patient_id, balance as so_du_khong_doi from wallets where patient_id = 2;

-- test 4: lỗi locked account (ví bị khóa)
-- bệnh nhân 3 (ví inactive, balance=1,000,000) mua 1 máy đo đường huyết
-- kết quả mong đợi: thất bại: ví đang bị khóa | balance không đổi
set @msg4 = '';
call processequipmentpurchase(3, 2, 1, @msg4);
select 'test case 4 - locked account' as ten_test, @msg4 as thong_bao;
select patient_id, balance as so_du_khong_doi, status from wallets where patient_id = 3;


-- xem trạng thái dữ liệu sau khi test
select 'du lieu sau khi test' as ghi_chu;
select product_id, name, price, stock from products;
select patient_id, balance, status from wallets;