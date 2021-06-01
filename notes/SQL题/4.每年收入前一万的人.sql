### 1.问题描述
现在有中国人从1980年到2020年每年每人的收入记录表A如下：
```sql
user_id     year      收入            
1           1980      100
2           1980      800
1           1981      200
2           1981      600
3           1981      400
1           1982      200
```
问题：求每年收入前一万的人。

* 方法一：窗口函数的方式

```sql
select
    user_id
    ,year
    ,income
from
(
    select 
        user_id
        ,year
        ,income
        ,row_number() over (partition by year order by income desc) as rk
    from incomes_stat
) t
where rk <= 10000
```

该方法存在问题：每年数据会有13亿条，单个reduce处理压力很大。

* 方法二：窗口函数的升级版本
> 思路：先根据身份证号码前四位预分组，将13亿数据分成1万组。

```sql
select
    user_id
    ,year
    ,income
from
(
    select
        user_id
        ,year
        ,income
        ,row_number() over (partition by year order by income desc) as rk_2
    from
    (
        select 
            user_id
            ,year
            ,income
            ,row_number() over (partition by year, substr(user_id, 1, 4) order by income desc) as rk
        from incomes_stat
    ) t
    where rk <= 10000
) s 
where rk_2 <= 10000
```
